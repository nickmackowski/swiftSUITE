"""
notes_capture.py — swiftNOTES/swiftCALENDAR remote capture engine (shared script)
──────────────────────────────────────────────────────────────────────────────
Checks one or more "remote send inbox" email accounts (configured by the user via swiftNOTES'
own account-management screen — see capture_accounts.json; nothing about any actual address
is hardcoded anywhere in this script) for new messages, and turns each one into either a note
or a calendar event depending on the subject-line prefix.

SUBJECT ROUTING: "c:" -> calendar event (written to swiftCALENDAR's local_events.json); "n:" or
no prefix at all -> note (written to swiftNOTES' notes.json, existing behavior, unchanged for
backward compatibility with everything already working). The prefix is stripped from the title
either way.

SHARED BY TWO APPS: this script is invoked by BOTH swiftNOTES (its own note capture) and
swiftCALENDAR (the c: routing) rather than each app keeping its own duplicate copy — one source
of truth for the IMAP/crypto logic, at the cost of a real cross-app dependency (if this file or
swiftNOTES' folder ever moves, swiftCALENDAR's remote-entry feature breaks too). Because of this,
every path in this script is anchored to the script's OWN fixed file location
(swiftNOTES/source_code/notes_capture.py), NOT to the current working directory — cwd differs
depending on which app invoked it (each app's own Process() call sets cwd to its own folder,
matching the suite-wide Process() convention), so relying on cwd here would silently break
depending on the caller.

Trigger: run when swiftNOTES OR swiftCALENDAR launches — NOT a background daemon. Mirrors
calendar_sync.py's existing pattern for the IMAP work. One background check covers every
configured account together (a single status line on the Swift side, not per-account progress).

capture_accounts.json format (an ARRAY of accounts, written by swiftNOTES' account-management
screen — supports more than one inbox):
[
  {
    "emailAddress": "user-provided-address@gmail.com",
    "imapHost": "imap.gmail.com",
    "imapPort": 993,
    "encryptedAppPassword": "<base64 AES-256-GCM ciphertext>",
    "pruneAfterCapture": true
  }
]

SECURITY NOTE: each account's app password is encrypted with a key derived the same way
swiftVAULT's own key is (SHA256(session-skey + "swiftVAULT")), NOT swiftNOTES' own key —
same security tier as anything actually stored in Vault, even though this file physically
lives in swiftNOTES' own folder rather than inside vault.json itself. That's a deliberate
choice: it avoids two different apps racing to write the same shared vault.json file, at the
cost of these credentials not being visible in Vault's own UI list.

DATE FORMAT NOTE — TWO DIFFERENT FORMATS, one per destination file:
- notes.json uses Swift's *default* JSONEncoder/JSONDecoder (no custom dateEncodingStrategy set
  anywhere in scn_main.swift) — Date fields are seconds-since-2001-01-01 (Cocoa reference date),
  NOT ISO8601 and NOT Unix epoch.
- local_events.json uses `.iso8601` explicitly (set in scc_main.swift's saveLocalEvents()) — a
  real ISO8601 string like "2026-08-15T15:00:00Z".
Getting either wrong doesn't just break the one new entry — JSONDecoder fails atomically on the
whole array, locking the user out of everything already in that file. Two separate helper
functions below (now_cocoa_timestamp()/parse_email_date_cocoa() for notes; the calendar event
builder's own ISO8601 formatting for events) exist specifically to keep these straight.

TIMESTAMP (notes only): dateCreated uses the email's own Date: header (when it was actually
sent), not when this script happened to process it — matters since the launch-check trigger
means real delay is possible between sending and capture (e.g. a text sent at 9am might not
get captured until swiftNOTES is next opened at 6pm; dateCreated should read 9am, not 6pm).
Falls back to processing time if the Date header is missing or unparseable. dateModified uses
the actual capture time instead — the moment it entered notes.json is a real modification event
in its own right (not-existing -> existing), distinct from when the content was originally
written.

TAGS (notes only): a "Tag: word1, word2" line (comma-separated, same one-line style as "Due:")
pulls extra tags out of the body — not [bracketed] words. Bracket syntax was dropped because
it's painful to type on an iOS keyboard (three keyboard layers to reach [ and ] on a stock
layout); a plain comma-separated line is much faster to type on a phone. Calendar events have no
tags system at all (CalendarEvent has no tags field), so this doesn't apply to c: messages.

CALENDAR EVENTS (c: messages only): a "Date: M/D[/YY] H:MMam/pm" line (one combined date+time
line, same single-line style as Due:/Tag:) becomes the event's start time; end time is always
exactly 1 hour later, no separate end-time input needed. isLocal is always true and
calendarName is always "Local" — matching exactly what a manually-typed local event in
swiftCALENDAR itself would get, since this genuinely is the same kind of event, just created
remotely. An unparseable or missing Date: line means the whole message is skipped for calendar
routing (logged, not silently dropped) rather than guessing a wrong time.

Dedupe/cleanup (both note and calendar messages, same rule): per account, a text-only message is
fully captured and deleted from that inbox after it's confirmed written to disk (see the
write-before-mark ordering below — deletion only ever happens after a successful save, never
before) — but ONLY if that account's pruneAfterCapture is true; if false, text-only messages are
kept+labeled the same as attachments are. A message WITH an attachment is always marked read and
copied into a "Captured" IMAP label instead, regardless of the prune setting, and never deleted —
v1 capture is text-only, so an attachment was never actually captured, and deleting it would make
it unrecoverable.
"""

import sys
import re
import os
import json
import uuid
import base64
import hashlib
import time
import imaplib
import email
import email.utils
from email.header import decode_header
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Anchored to this script's own fixed location (swiftNOTES/source_code/notes_capture.py), NOT
# to the current working directory — see the module docstring above for why this matters now
# that swiftCALENDAR invokes this script too, with a different cwd than swiftNOTES uses.
SCRIPT_DIR = Path(__file__).resolve().parent      # swiftNOTES/source_code/
NOTES_APP_ROOT = SCRIPT_DIR.parent                 # swiftNOTES/
SUITE_ROOT = NOTES_APP_ROOT.parent                 # swiftSUITE/

ACCOUNTS_FILE = NOTES_APP_ROOT / "capture_accounts.json"
NOTES_FILE = NOTES_APP_ROOT / "notes.json"
CALENDAR_LOCAL_EVENTS_FILE = SUITE_ROOT / "swiftcalendar" / "local_events.json"
SESSION_FILE = SUITE_ROOT / "swiftcore" / ".core_session"
CAPTURE_LABEL = "Captured"

# Seconds between the Unix epoch (1970-01-01) and the Cocoa/Core Data reference date
# (2001-01-01) that Swift's default Date JSON encoding is measured from.
COCOA_EPOCH_OFFSET = 978307200


def now_cocoa_timestamp() -> float:
    return datetime.now(timezone.utc).timestamp() - COCOA_EPOCH_OFFSET


def parse_email_date_cocoa(msg) -> float:
    """Parses the email's own Date: header into a Cocoa timestamp, for dateCreated/
    dateModified. Falls back to now_cocoa_timestamp() if the header is missing or
    unparseable — same graceful-degradation philosophy as the rest of this script, never
    crash or block a capture on one malformed message."""
    raw_date = msg.get("Date")
    if not raw_date:
        return now_cocoa_timestamp()
    try:
        dt = email.utils.parsedate_to_datetime(raw_date)
        if dt is None:
            return now_cocoa_timestamp()
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp() - COCOA_EPOCH_OFFSET
    except Exception:
        return now_cocoa_timestamp()


def parse_due_date_cocoa(due_str):
    """Loosely parses a due-date string like '7/30', '07/30/26', or '07/30/2026' into a Cocoa
    timestamp for the Note's dueDate field. Returns None if unparseable — a due date that can't
    be parsed just doesn't get set; the note is still captured either way."""
    if not due_str:
        return None
    for fmt in ("%m/%d/%y", "%m/%d/%Y", "%m/%d"):
        try:
            dt = datetime.strptime(due_str.strip(), fmt)
            if fmt == "%m/%d":
                dt = dt.replace(year=datetime.now().year)
            # Noon UTC, not midnight — a due date has no time component, just a calendar date.
            # Midnight UTC rolls back to the evening of the PREVIOUS day in any negative-UTC-
            # offset local timezone (US Eastern, Central, etc.) once swiftCALENDAR's due-date
            # overlay displays it — same bug class, same fix, as calendar_sync.py's all-day ICS
            # event parsing. Noon UTC never crosses a day boundary for any realistic timezone.
            dt = dt.replace(hour=12, tzinfo=timezone.utc)
            return dt.timestamp() - COCOA_EPOCH_OFFSET
        except ValueError:
            continue
    return None


def derive_app_key(skey: bytes, app_id: str) -> bytes:
    """Matches Swift's readCoreSessionKey app-specific derivation — SHA256(skey + appID). Same
    function already proven correct in swiftADMIN.py's master-password-change tooling."""
    h = hashlib.sha256()
    h.update(skey)
    h.update(app_id.encode("utf-8"))
    return h.digest()


def aes_gcm_decrypt(ciphertext_b64: str, key: bytes) -> str:
    """AES-256-GCM decrypt matching Swift's AES.GCM — format: nonce(12) + ciphertext + tag(16).
    Same format swiftADMIN.py's aes_gcm_decrypt() already uses."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    data = base64.b64decode(ciphertext_b64)
    nonce, payload = data[:12], data[12:]
    return AESGCM(key).decrypt(nonce, payload, None).decode("utf-8")


def aes_gcm_encrypt(plaintext: str, key: bytes) -> str:
    """AES-256-GCM encrypt matching Swift's AES.GCM — format: nonce(12) + ciphertext + tag(16)."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = os.urandom(12)
    payload = AESGCM(key).encrypt(nonce, plaintext.encode("utf-8"), None)
    return base64.b64encode(nonce + payload).decode("utf-8")


def read_session_skey():
    """Reads the base64 'skey' from swiftCORE's already-active .core_session file. This script
    never prompts for the master password itself — it only ever runs while a session is
    active (swiftNOTES/swiftCALENDAR trigger it on launch, after the user has already unlocked
    things)."""
    session_file = SESSION_FILE
    if not session_file.exists():
        return None
    expires = 0.0
    skey_b64 = ""
    try:
        content = session_file.read_text(encoding="utf-8")
    except OSError:
        return None
    for line in content.splitlines():
        parts = line.split(":", 1)
        if len(parts) < 2:
            continue
        if parts[0] == "expires":
            try:
                expires = float(parts[1])
            except ValueError:
                pass
        elif parts[0] == "skey":
            skey_b64 = parts[1]
    if not skey_b64 or time.time() >= expires:
        return None
    try:
        return base64.b64decode(skey_b64)
    except Exception:
        return None


def load_accounts():
    """Returns a list of account dicts (capture_accounts.json is an array — supports more than
    one remote send inbox). Empty list if the file doesn't exist yet or fails to parse."""
    if not os.path.exists(ACCOUNTS_FILE):
        print(f"No {ACCOUNTS_FILE} found — add a capture account via swiftNOTES first.")
        return []
    try:
        with open(ACCOUNTS_FILE, encoding="utf-8") as f:
            accounts = json.load(f)
        if not isinstance(accounts, list):
            print(f"{ACCOUNTS_FILE} is not a list — expected an array of accounts.")
            return []
        return accounts
    except Exception as e:
        print(f"Error reading {ACCOUNTS_FILE}: {e}")
        return []


def load_notebook_file():
    """notes.json is NOT a bare array -- it's a NotebookFile wrapper (formatVersion, kdfSalt,
    kdfIterations, canary, notes, lastBackupTimestamp). Every field except `notes` must be
    preserved exactly as-is when writing back, or the file becomes undecodable."""
    if not os.path.exists(NOTES_FILE):
        print(f"No {NOTES_FILE} found — nothing to append captured notes to.")
        return None
    try:
        with open(NOTES_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error reading {NOTES_FILE}: {e}")
        return None


def decode_mime_words(s):
    """Decodes a MIME-encoded email header (e.g. subject) into a plain string."""
    if not s:
        return ""
    decoded = ""
    for text, enc in decode_header(s):
        if isinstance(text, bytes):
            decoded += text.decode(enc or "utf-8", errors="replace")
        else:
            decoded += text
    return decoded


def has_attachment(msg):
    """True if the message has any part carrying a filename or explicit attachment disposition.
    v1 capture is text-only (get_plain_body() below skips anything but text/plain), so a message
    with an attachment is never fully captured — used to decide whether it's safe to delete after
    processing (text-only, and the account allows pruning) or should be preserved via the
    mark-read+label safety net instead (always, regardless of the account's prune setting)."""
    if not msg.is_multipart():
        return False
    for part in msg.walk():
        disp = str(part.get("Content-Disposition") or "")
        if "attachment" in disp.lower():
            return True
        if part.get_filename():
            return True
    return False


def get_plain_body(msg):
    """Extracts the plain-text body from an email.message.Message, skipping attachments. v1
    scope: text/body only — attachments are a known limitation, not a blocker."""
    if msg.is_multipart():
        for part in msg.walk():
            disp = str(part.get("Content-Disposition") or "")
            if part.get_content_type() == "text/plain" and "attachment" not in disp:
                charset = part.get_content_charset() or "utf-8"
                payload = part.get_payload(decode=True)
                if payload:
                    return payload.decode(charset, errors="replace")
        return ""
    charset = msg.get_content_charset() or "utf-8"
    payload = msg.get_payload(decode=True)
    return payload.decode(charset, errors="replace") if payload else ""


def extract_tags_and_due(body):
    """Pulls a 'Tag: word1, word2' line (comma-separated) out as extra tags, and a
    'Due: <date>' line into a due date — both stripped out of the saved body. Both are
    optional; a plain email with neither still works fine as an ordinary captured note.

    Tags used to be [bracketed] words, matching the convention calendar_sync.py already uses
    for ICS feeds — changed to a comma-separated line because bracket syntax is genuinely
    painful to type on an iOS keyboard (three keyboard layers to reach [ and ] on a stock
    layout), while a "Tag:" line types as fast as "Due:" already did."""
    tag_pattern = re.compile(r"^\s*Tag:\s*(.+)$", re.IGNORECASE)
    due_pattern = re.compile(r"^\s*Due:\s*(.+)$", re.IGNORECASE)

    tags, seen = [], set()
    due_date_str = None
    cleaned_lines = []

    for line in body.splitlines():
        tag_match = tag_pattern.match(line)
        due_match = due_pattern.match(line)
        if tag_match:
            for raw_tag in tag_match.group(1).split(","):
                tag = raw_tag.strip().lower()
                if tag and tag not in seen:
                    tags.append(tag)
                    seen.add(tag)
            continue
        if due_match:
            due_date_str = due_match.group(1).strip()
            continue
        cleaned_lines.append(line)

    cleaned_body = "\n".join(cleaned_lines).strip()
    return tags, due_date_str, cleaned_body


def load_calendar_events():
    """local_events.json is a bare array (not a wrapper object like notes.json) — written
    directly by swiftCALENDAR itself (saveLocalEvents()) whenever any local event is saved,
    including manually-typed ones. Perfectly normal for this file not to exist yet on a fresh
    install (no local events ever saved) — starts from an empty list in that case, not treated
    as an error the way a missing notes.json would be."""
    if not CALENDAR_LOCAL_EVENTS_FILE.exists():
        return []
    try:
        with open(CALENDAR_LOCAL_EVENTS_FILE, encoding="utf-8") as f:
            events = json.load(f)
        if not isinstance(events, list):
            print(f"{CALENDAR_LOCAL_EVENTS_FILE} is not a list — expected an array of events.")
            return []
        return events
    except Exception as e:
        print(f"Error reading {CALENDAR_LOCAL_EVENTS_FILE}: {e}")
        return []


def route_subject(subject):
    """Detects the c:/n: routing prefix and strips it from the title either way. No prefix at
    all defaults to "note", same as before this feature existed — backward compatible with
    everything already working, so nothing about existing captured-note behavior changes."""
    stripped = subject.strip()
    if re.match(r"^c:\s*", stripped, re.IGNORECASE):
        title = re.sub(r"^c:\s*", "", stripped, flags=re.IGNORECASE).strip()
        return "calendar", title or "Untitled Event"
    if re.match(r"^n:\s*", stripped, re.IGNORECASE):
        title = re.sub(r"^n:\s*", "", stripped, flags=re.IGNORECASE).strip()
        return "note", title or "Untitled Captured Note"
    return "note", stripped or "Untitled Captured Note"


def parse_calendar_event_datetime(raw):
    """Parses a 'Date:' line into a timezone-aware datetime, plus whether it's an all-day
    event. Two forms are accepted:
      - Date + time: 'M/D[/YY] H:MMam/pm' (e.g. '8/15 3:00p', '8/15/26 3pm') -> a timed event
      - Date only: 'M/D[/YY]' (e.g. '8/26/26') -> an all-day event, anchored at noon local
        time (isAllDay is what actually drives display; noon is just a safe, unambiguous
        anchor point that won't drift onto the wrong calendar day if interpreted in a
        different timezone somewhere downstream, same reasoning calendar_sync.py already
        uses for TAF's own all-day anchor time)
    No timezone is given in the email, so this is treated as LOCAL time on the machine
    running this script — the same machine running swiftCALENDAR, in the user's own
    timezone — not UTC. Returns None if unparseable, meaning the whole message just doesn't
    become a calendar event rather than guessing a wrong time. Returns (datetime, is_all_day)
    on success."""
    raw = raw.strip()
    parts = raw.split(None, 1)
    if len(parts) == 1:
        date_part, time_part = parts[0], None
    elif len(parts) == 2:
        date_part, time_part = parts[0], parts[1].strip()
    else:
        return None

    local_tz = datetime.now().astimezone().tzinfo

    if time_part is None:
        # Date only -> all-day event.
        for date_fmt in ("%m/%d/%y", "%m/%d/%Y", "%m/%d"):
            try:
                dt = datetime.strptime(date_part, date_fmt)
                if date_fmt == "%m/%d":
                    dt = dt.replace(year=datetime.now().year)
                dt = dt.replace(hour=12, minute=0)
                return dt.replace(tzinfo=local_tz), True
            except ValueError:
                continue
        return None

    time_norm = time_part.lower().replace(" ", "")
    m = re.match(r"^(\d{1,2})(:(\d{2}))?(am|pm|a|p)?$", time_norm)
    if not m:
        return None
    hour = int(m.group(1))
    minute = int(m.group(3)) if m.group(3) else 0
    ampm = m.group(4)
    if ampm:
        ampm_full = "AM" if ampm.startswith("a") else "PM"
        time_str = f"{hour}:{minute:02d}{ampm_full}"
        time_fmt = "%I:%M%p"
    else:
        time_str = f"{hour}:{minute:02d}"
        time_fmt = "%H:%M"

    for date_fmt in ("%m/%d/%y", "%m/%d/%Y", "%m/%d"):
        try:
            combined = f"{date_part} {time_str}"
            combined_fmt = f"{date_fmt} {time_fmt}"
            dt = datetime.strptime(combined, combined_fmt)
            if date_fmt == "%m/%d":
                dt = dt.replace(year=datetime.now().year)
            return dt.replace(tzinfo=local_tz), False
        except ValueError:
            continue
    return None


def build_calendar_event(title, body):
    """Parses a 'Date:' line out of the body (same single-line style as Due:/Tag:) and builds
    a CalendarEvent-shaped dict ready to append to local_events.json. Returns None if there's
    no Date: line or it doesn't parse — the message just doesn't become a calendar event in
    that case (logged by the caller, not silently dropped). 'Date: M/D[/YY] H:MMam/pm' makes a
    timed event ending exactly 1 hour after start; 'Date: M/D[/YY]' with no time makes an
    all-day event instead — no separate end-time input needed in the email either way.
    isLocal is always true and calendarName is always "Local", matching exactly what a
    manually-typed local event in swiftCALENDAR itself would get — this genuinely is the same
    kind of event, just created remotely; no special "came from remote send" marking (deliberate
    choice — CalendarEvent has no tags system the way Note does, so there's nothing natural to
    hang a marker on, and no functional use for one anyway)."""
    date_pattern = re.compile(r"^\s*Date:\s*(.+)$", re.IGNORECASE)
    date_line = None
    cleaned_lines = []
    for line in body.splitlines():
        m = date_pattern.match(line)
        if m and date_line is None:
            date_line = m.group(1).strip()
            continue
        cleaned_lines.append(line)
    cleaned_body = "\n".join(cleaned_lines).strip()

    if not date_line:
        return None
    parsed = parse_calendar_event_datetime(date_line)
    if parsed is None:
        return None
    start_dt, is_all_day = parsed

    end_dt = start_dt if is_all_day else start_dt + timedelta(hours=1)
    start_utc = start_dt.astimezone(timezone.utc)
    end_utc = end_dt.astimezone(timezone.utc)

    return {
        "id": str(uuid.uuid4()).upper(),
        "title": title,
        "location": "",
        "startTime": start_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endTime": end_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "notes": cleaned_body,
        "calendarName": "Local",
        "isAllDay": is_all_day,
        "isLocal": True,
    }


def capture_new_notes():
    accounts = load_accounts()
    if not accounts:
        return False

    # notebook can legitimately be None (e.g. this script runs before swiftNOTES has ever been
    # launched even once) without blocking calendar routing — the two destinations are
    # independent, so a problem with one doesn't need to stop the other. Guarded per-message
    # below rather than an early return here.
    notebook = load_notebook_file()
    calendar_events = load_calendar_events()

    skey = read_session_skey()
    if not skey:
        print("No active swiftCORE session — can't decrypt capture-inbox passwords. "
              "Open swiftNOTES or swiftCALENDAR to unlock, then try again.")
        return False
    vault_key    = derive_app_key(skey, "swiftVAULT")
    notebook_key = derive_app_key(skey, "swiftNOTES")

    total_notes_captured = 0
    total_events_captured = 0

    for account in accounts:
        email_address = account.get("emailAddress", "(unknown)")
        prune_after_capture = account.get("pruneAfterCapture", True)

        try:
            app_password = aes_gcm_decrypt(account["encryptedAppPassword"], vault_key)
        except Exception as e:
            print(f"[{email_address}] Could not decrypt password: {e}")
            continue

        try:
            imap = imaplib.IMAP4_SSL(account["imapHost"], account.get("imapPort", 993))
            imap.login(email_address, app_password)
        except Exception as e:
            print(f"[{email_address}] Could not connect: {e}")
            continue

        imap.select("INBOX")
        # Only unread mail -- already-processed messages are marked read + labeled below, so
        # this naturally skips anything already captured with no separate tracking file needed.
        #
        # UID-based throughout (search/fetch/store/copy), not sequence numbers -- Gmail (and
        # IMAP servers generally) can shift sequence numbers mid-session once a flag changes or
        # a message gets copied elsewhere, which breaks a loop that fetches message N+1 using a
        # sequence number captured before message N was flagged/copied. UIDs stay stable for the
        # whole session.
        status, data = imap.uid("search", None, "UNSEEN")
        if status != "OK" or not data or not data[0]:
            print(f"[{email_address}] No new messages.")
            imap.logout()
            continue

        message_uids = data[0].split()
        any_deleted = False

        for msg_uid in message_uids:
            try:
                status, msg_data = imap.uid("fetch", msg_uid, "(RFC822)")
                if status != "OK" or not msg_data or not msg_data[0] or not isinstance(msg_data[0], tuple):
                    print(f"[{email_address}]   Skipped a message — unexpected fetch response for UID {msg_uid!r}.")
                    continue
                msg = email.message_from_bytes(msg_data[0][1])
                msg_has_attachment = has_attachment(msg)

                raw_subject = decode_mime_words(msg.get("Subject", "")).strip()
                body = get_plain_body(msg)
                route, title = route_subject(raw_subject)

                captured_ok = False

                if route == "calendar":
                    event = build_calendar_event(title, body)
                    if event is None:
                        print(f"[{email_address}]   Skipped '{title}' — no parseable Date: line, not captured as a calendar event.")
                        continue
                    calendar_events.append(event)
                    # Persist immediately, BEFORE marking the message read -- same write-before-
                    # mark ordering as notes below, for the same reason: a crash partway through
                    # a batch can't leave an earlier message marked \Seen with its content never
                    # actually saved.
                    try:
                        with open(CALENDAR_LOCAL_EVENTS_FILE, "w", encoding="utf-8") as f:
                            json.dump(calendar_events, f, indent=2)
                    except Exception as e:
                        print(f"[{email_address}]   Skipped '{title}' — couldn't save to {CALENDAR_LOCAL_EVENTS_FILE}: {e}")
                        calendar_events.pop()
                        continue
                    total_events_captured += 1
                    print(f"[{email_address}]   Captured event: {title}")
                    captured_ok = True

                else:  # route == "note"
                    if notebook is None:
                        print(f"[{email_address}]   Skipped '{title}' — {NOTES_FILE} isn't available (open swiftNOTES at least once first).")
                        continue

                    extra_tags, due_str, cleaned_body = extract_tags_and_due(body)
                    due_cocoa = parse_due_date_cocoa(due_str)

                    try:
                        encrypted_body = aes_gcm_encrypt(cleaned_body, notebook_key)
                    except Exception as e:
                        print(f"[{email_address}]   Skipped '{title}' — encryption failed: {e}")
                        continue

                    created_ts = parse_email_date_cocoa(msg)  # when it was actually written/sent
                    modified_ts = now_cocoa_timestamp()        # when it was actually captured — a
                                                                 # real modification event in its own
                                                                 # right (not-existing -> existing),
                                                                 # distinct from when the content was
                                                                 # originally written
                    new_note = {
                        "title": title,
                        "encryptedBody": encrypted_body,
                        "tags": ["rsend"] + extra_tags,
                        "dateCreated": created_ts,
                        "dateModified": modified_ts,
                        "isArchived": False,
                    }
                    if due_cocoa is not None:
                        new_note["dueDate"] = due_cocoa

                    notebook["notes"].append(new_note)

                    # Persist immediately, BEFORE marking the message read — keeps "saved to
                    # disk" and "flagged read on the server" in sync per message.
                    try:
                        with open(NOTES_FILE, "w", encoding="utf-8") as f:
                            json.dump(notebook, f, indent=2)
                    except Exception as e:
                        print(f"[{email_address}]   Skipped '{title}' — couldn't save to {NOTES_FILE}: {e}")
                        notebook["notes"].pop()  # undo the in-memory append, nothing was persisted
                        continue

                    total_notes_captured += 1
                    print(f"[{email_address}]   Captured: {title}")
                    captured_ok = True

                if not captured_ok:
                    continue

                if msg_has_attachment or not prune_after_capture:
                    # Always kept+labeled if it has an attachment (v1 doesn't capture those,
                    # deleting would make it unrecoverable), regardless of the account's prune
                    # setting. Also kept+labeled for a text-only message on an account where
                    # pruning is turned off. Same rule for both notes and calendar events.
                    imap.uid("store", msg_uid, "+FLAGS", "\\Seen")
                    try:
                        imap.create(CAPTURE_LABEL)  # no-op if it already exists
                    except Exception:
                        pass
                    try:
                        imap.uid("copy", msg_uid, CAPTURE_LABEL)
                    except Exception as e:
                        print(f"[{email_address}]   Warning: couldn't copy to '{CAPTURE_LABEL}' label: {e}")
                    reason = "has an attachment v1 doesn't capture" if msg_has_attachment else "pruning is off for this account"
                    print(f"[{email_address}]   (kept — {reason})")
                else:
                    # Text-only, this account allows pruning, and already confirmed written to
                    # disk above -- fully captured, safe to remove. Flags for deletion here; the
                    # actual expunge happens once after this account's whole batch finishes, one
                    # round trip instead of one per message.
                    imap.uid("store", msg_uid, "+FLAGS", "\\Deleted")
                    any_deleted = True

            except Exception as e:
                # One malformed/unusual message shouldn't abandon the rest of the batch.
                print(f"[{email_address}]   Skipped a message (UID {msg_uid!r}) — {e}")
                continue

        if any_deleted:
            try:
                imap.expunge()
            except Exception as e:
                print(f"[{email_address}] Warning: couldn't expunge deleted messages: {e}")

        imap.logout()

    if total_notes_captured > 0 or total_events_captured > 0:
        print(f"\nCaptured {total_notes_captured} note(s) and {total_events_captured} calendar event(s).")
    else:
        print("No new messages across any capture account.")
    return True


if __name__ == "__main__":
    # Detaches this process from whatever controlling terminal/session it inherited from the
    # Swift app that launched it (swiftNOTES or swiftCALENDAR). Redirecting standardInput to
    # /dev/null on the Swift side (Process.standardInput) only changes which file descriptor is
    # attached to fd 0 -- it does NOT detach this process from the same terminal *session* the
    # parent app's own raw-mode reading depends on, which turned out to still cause real
    # interference (confirmed: a "1/2 selection frozen, no visible echo" bug in swiftCALENDAR's
    # account-setup screen that only occurred while this script's background launch-check was
    # still running, and went away once it wasn't). os.setsid() is the actual fix — it makes
    # this process a new session leader with no controlling terminal at all. Wrapped in a
    # try/except since it raises OSError if the process is already a session leader (harmless,
    # not fatal — same graceful-degradation philosophy as the rest of this script).
    try:
        os.setsid()
    except OSError:
        pass
    success = capture_new_notes()
    sys.exit(0 if success else 1)