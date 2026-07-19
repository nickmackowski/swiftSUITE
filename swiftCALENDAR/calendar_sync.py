"""
calendar_sync.py — swiftCALENDAR sync engine v2.7
─────────────────────────────────────────────────
Reads calendar account configs from calendar_accounts.json (written by
swiftCALENDAR's [A] Account Setup screen) and fetches ICS feeds for all
enabled accounts. Writes merged events to calendar.json.

calendar_accounts.json format:
[
  {"name": "Outlook", "url": "https://...", "enabled": true, "colorIndex": 0},
  {"name": "Apple",   "url": "https://...", "enabled": true, "colorIndex": 1}
]

To migrate: run swiftCALENDAR, press [A], add your calendar accounts,
then sync with [R].
"""

import sys
import re
import uuid
import json
import os
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

ACCOUNTS_FILE = "calendar_accounts.json"
OUTPUT_FILE   = "calendar.json"


def load_accounts():
    if not os.path.exists(ACCOUNTS_FILE):
        print(f"No {ACCOUNTS_FILE} found. Use swiftCALENDAR > [A] Account Setup to add calendars.")
        return []
    try:
        with open(ACCOUNTS_FILE, encoding="utf-8") as f:
            accounts = json.load(f)
        enabled = [a for a in accounts if a.get("enabled", True) and
                   (a.get("url", "").startswith("http") or a.get("type", "ics") in ("metar", "taf"))]
        print(f"Loaded {len(enabled)} enabled account(s) from {ACCOUNTS_FILE}.")
        return enabled
    except Exception as e:
        print(f"Error reading {ACCOUNTS_FILE}: {e}")
        return []


def fetch_metar(station_id, calendar_label):
    """Fetch today's and yesterday's METAR — creates up to 2 all-day events."""
    url = f"https://aviationweather.gov/api/data/metar?ids={station_id}&format=raw&hours=26"
    print(f"  Fetching METAR for {station_id}...")
    try:
        req = urllib.request.Request(url=url, headers={"User-Agent": "swiftCALENDAR/2.7"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8", errors="ignore").strip()
    except Exception as e:
        print(f"  Warning: Could not fetch METAR for {station_id}: {e}")
        return []

    lines = [l.strip() for l in raw.splitlines() if l.strip()]
    if not lines:
        print(f"  Warning: Empty METAR response for {station_id}")
        return []

    import re as _re
    now       = datetime.now()
    today_day = now.strftime("%d")
    yest_day  = (now - timedelta(days=1)).strftime("%d")

    def parse_one(metar, event_date):
        """Parse a single METAR line into a calendar event dict."""
        metar_short = metar.split(" RMK")[0].strip()
        td_match = _re.search(r"\b(M?\d{2})/(M?\d{2})\b", metar)
        temp_suffix = ""
        if td_match:
            def to_f(s):
                val = -int(s[1:]) if s.startswith("M") else int(s)
                return round(val * 9 / 5 + 32)
            temp_suffix = f"{to_f(td_match.group(1))}°F/{to_f(td_match.group(2))}°F"
        title = _re.sub(r'^(METAR|SPECI)\s+', '', metar_short, flags=_re.IGNORECASE).strip()
        if title.upper().startswith(station_id.upper() + " "):
            title = title[len(station_id)+1:].strip()
        start = event_date.strftime("%Y-%m-%dT12:00:00Z")
        end   = (event_date + timedelta(days=1)).strftime("%Y-%m-%dT12:00:00Z")
        return {
            "id":           str(uuid.uuid4()).upper(),
            "title":        title,
            "location":     station_id,
            "startTime":    start,
            "endTime":      end,
            "notes":        temp_suffix,
            "tags":         [],
            "calendarName": calendar_label,
            "isAllDay":     True,
            "isLocal":      False,
        }

    events = []
    found_today = False
    found_yest  = False

    for line in lines:
        # Extract day from METAR timestamp (DDHHMM Z format)
        ts_match = _re.search(r'\b(\d{2})\d{4}Z\b', line)
        if not ts_match:
            continue
        day = ts_match.group(1)
        if day == today_day and not found_today:
            events.append(parse_one(line, now))
            found_today = True
            print(f"  METAR today: {line[:50]}")
        elif day == yest_day and not found_yest:
            events.append(parse_one(line, now - timedelta(days=1)))
            found_yest = True
            print(f"  METAR yesterday: {line[:50]}")
        if found_today and found_yest:
            break

    return events



def fetch_nws_temps_tomorrow(lat, lon):
    """Fetch tomorrow's high/low from NWS API. Returns (high_f, low_f) or (None, None)."""
    try:
        # Step 1: get grid endpoint for this lat/lon
        points_url = f"https://api.weather.gov/points/{lat},{lon}"
        req = urllib.request.Request(points_url, headers={
            "User-Agent": "swiftCALENDAR/2.7",
            "Accept": "application/geo+json"
        })
        with urllib.request.urlopen(req, timeout=10) as resp:
            points = json.loads(resp.read().decode("utf-8"))
        forecast_url = points["properties"]["forecast"]

        # Step 2: get forecast
        req2 = urllib.request.Request(forecast_url, headers={
            "User-Agent": "swiftCALENDAR/2.7",
            "Accept": "application/geo+json"
        })
        with urllib.request.urlopen(req2, timeout=10) as resp2:
            forecast = json.loads(resp2.read().decode("utf-8"))

        periods = forecast["properties"]["periods"]
        # Find tomorrow's daytime and overnight periods
        tomorrow = (datetime.utcnow() + timedelta(days=1)).strftime("%Y-%m-%d")
        high_f, low_f = None, None
        for period in periods:
            start = period.get("startTime", "")
            if tomorrow in start:
                temp = period.get("temperature")
                is_day = period.get("isDaytime", True)
                if is_day and high_f is None:
                    high_f = temp
                elif not is_day and low_f is None:
                    low_f = temp
            if high_f is not None and low_f is not None:
                break
        return high_f, low_f
    except Exception as e:
        print(f"  Note: NWS temp fetch failed: {e}")
        return None, None


def fetch_taf(station_id, calendar_label, **kwargs):
    """Fetch TAF for a station and return a single all-day event for tomorrow."""
    url = f"https://aviationweather.gov/api/data/taf?ids={station_id}&format=raw&hours=30"
    print(f"  Fetching TAF for {station_id}...")
    try:
        req = urllib.request.Request(url=url, headers={"User-Agent": "swiftCALENDAR/2.7"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8", errors="ignore").strip()
    except Exception as e:
        print(f"  Warning: Could not fetch TAF for {station_id}: {e}")
        return []

    if not raw:
        print(f"  Warning: Empty TAF response for {station_id}")
        return []

    import re as _re
    # Unfold continuation lines
    unfolded = raw.replace("\r\n ", "").replace("\n ", "").replace("\r ", "")
    lines = [l.strip() for l in unfolded.splitlines() if l.strip()]

    # Search full text for the FM group covering tomorrow
    # Use the RAW (not unfolded) text so FM groups are preserved as tokens
    now      = datetime.now()  # local time
    tomorrow = now + timedelta(days=1)
    tmrw_day = tomorrow.strftime("%d")

    taf_line = ""
    # Find FM{DD}HHMM followed by conditions up to next FM/PROB/TEMPO/BECMG or end
    fm_pattern = r'FM' + tmrw_day + r'\d{4}\s+(.*?)(?=FM\d{6}|PROB\d+\s|TEMPO\s|BECMG\s|$)'
    fm_match = _re.search(fm_pattern, raw, _re.DOTALL)
    if fm_match:
        taf_line = fm_match.group(1).replace('\r\n', ' ').replace('\n', ' ').replace('\r', ' ').strip()
        taf_line = _re.sub(r'\s+', ' ', taf_line).strip()

    # Fallback: strip TAF prefix, station ID and issuance/valid period from first line
    if not taf_line:
        first = _re.sub(r'^(TAF|METAR)\s+', '', raw.splitlines()[0] if raw.splitlines() else '', flags=_re.IGNORECASE).strip()
        if first.upper().startswith(station_id.upper()):
            first = first[len(station_id):].strip()
        first = _re.sub(r'^\d{6}Z\s*\d{4}/\d{4}\s*', '', first).strip()
        taf_line = first

    # Strip any leading TAF/METAR type designator or station ID that slipped through
    taf_line = _re.sub(r'^(TAF|METAR)\s+', '', taf_line, flags=_re.IGNORECASE).strip()
    if taf_line.upper().startswith(station_id.upper() + " "):
        taf_line = taf_line[len(station_id)+1:].strip()
    # Strip issuance time and valid period if still present (DDHHMMZ DDDD/DDDD)
    taf_line = _re.sub(r'^\d{6}Z\s*\d{4}/\d{4}\s*', '', taf_line).strip()

    if not taf_line:
        print(f"  Warning: Could not parse TAF for {station_id}")
        return []

    # Fetch tomorrow's high/low from NWS if lat/lon provided
    temp_c_str  = ""
    temp_f_str  = ""
    lat = kwargs.get("lat")
    lon = kwargs.get("lon")
    if lat and lon:
        high_f, low_f = fetch_nws_temps_tomorrow(lat, lon)
        if high_f is not None and low_f is not None:
            high_c = round((high_f - 32) * 5 / 9)
            low_c  = round((low_f  - 32) * 5 / 9)
            temp_c_str = f" {high_c}/{low_c}"
            temp_f_str = f"{high_f}°F/{low_f}°F"
            print(f"  NWS temps tomorrow: {high_f}°F/{low_f}°F")

    full_title = f"{taf_line}{temp_c_str}"
    print(f"  TAF tomorrow: {full_title[:60]}")
    tmrw_start = tomorrow.strftime("%Y-%m-%dT12:00:00Z")
    tmrw_end   = (tomorrow + timedelta(days=2)).strftime("%Y-%m-%dT12:00:00Z")

    return [{
        "id":           str(uuid.uuid4()).upper(),
        "title":        full_title,
        "location":     station_id,
        "startTime":    tmrw_start,
        "endTime":      tmrw_end,
        "notes":        temp_f_str,   # red display in Swift agenda, same as METAR
        "tags":         [],
        "calendarName": calendar_label,
        "isAllDay":     True,
        "isLocal":      False,
    }]


def parse_ics_date(raw_line):
    # Windows → IANA timezone name mapping (Outlook uses Windows names)
    WINDOWS_TZ = {
        "Eastern Standard Time":   "America/New_York",
        "Eastern Daylight Time":   "America/New_York",
        "Central Standard Time":   "America/Chicago",
        "Central Daylight Time":   "America/Chicago",
        "Mountain Standard Time":  "America/Denver",
        "Mountain Daylight Time":  "America/Denver",
        "Pacific Standard Time":   "America/Los_Angeles",
        "Pacific Daylight Time":   "America/Los_Angeles",
        "UTC":                     "UTC",
        "Greenwich Standard Time": "UTC",
        "US Eastern Standard Time":"America/Indiana/Indianapolis",
        "US Mountain Standard Time":"America/Phoenix",
        "Hawaiian Standard Time":  "Pacific/Honolulu",
        "Alaskan Standard Time":   "America/Anchorage",
    }

    date_str = raw_line.strip()
    tzid = None
    tzid_match = re.search(r"TZID=([^:;]+)", date_str)
    if tzid_match:
        raw_tzid = tzid_match.group(1).strip()
        tzid = WINDOWS_TZ.get(raw_tzid, raw_tzid)  # map Windows → IANA if possible
    if ":" in date_str:
        date_str = date_str.split(":")[-1]
    if len(date_str) == 8 and date_str.isdigit():
        return f"{date_str[:4]}-{date_str[4:6]}-{date_str[6:8]}T00:00:00Z", True
    is_utc = date_str.endswith("Z")
    clean  = date_str.replace("T", "").rstrip("Z")
    if len(clean) < 14:
        return None, False
    try:
        naive_dt = datetime.strptime(clean[:14], "%Y%m%d%H%M%S")
    except Exception:
        return None, False
    if is_utc:
        utc_dt = naive_dt  # explicit UTC — keep as-is
    elif tzid is None:
        # Floating time (no Z, no TZID) — treat as local system time
        import time as _time
        local_offset = _time.timezone if not _time.localtime().tm_isdst else _time.altzone
        utc_dt = naive_dt + timedelta(seconds=local_offset)
    else:
        try:
            zone   = ZoneInfo(tzid)
            aware  = naive_dt.replace(tzinfo=zone)
            utc_dt = aware.astimezone(ZoneInfo("UTC")).replace(tzinfo=None)
        except Exception:
            # Unrecognized TZID — fall back to local time rather than UTC
            import time as _time
            local_offset = _time.timezone if not _time.localtime().tm_isdst else _time.altzone
            utc_dt = naive_dt + timedelta(seconds=local_offset)
    return utc_dt.strftime("%Y-%m-%dT%H:%M:%SZ"), False


def get_date_bounds():
    now = datetime.utcnow()
    first_of_current = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    last_of_prev     = first_of_current - timedelta(days=1)
    start_filter     = last_of_prev.replace(day=1)
    if now.month >= 11:
        first_two_out = now.replace(year=now.year + 1, month=(now.month + 2) % 12, day=1)
    else:
        first_two_out = now.replace(month=now.month + 2, day=1)
    end_filter = first_two_out - timedelta(seconds=1)
    return start_filter, end_filter


def fetch_and_parse_feed(url, calendar_label, start_filter, end_filter):
    print(f"  Fetching {calendar_label}...")
    req = urllib.request.Request(url=url, headers={"User-Agent": "swiftCALENDAR/2.7"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status != 200:
                print(f"  Warning: {calendar_label} returned HTTP {resp.status}")
                return []
            raw = resp.read().decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"  Warning: Could not fetch {calendar_label}: {e}")
        return []

    # RFC 5545 line unfolding — continuation lines start with SPACE or TAB after CRLF or LF
    unfolded = raw
    for fold in ("\r\n\t", "\r\n ", "\n\t", "\n ", "\r\t", "\r "):
        unfolded = unfolded.replace(fold, "")
    blocks   = unfolded.split("BEGIN:VEVENT")
    if len(blocks) <= 1:
        return []

    parsed = []
    for block in blocks[1:]:
        if "END:VEVENT" in block:
            block = block.split("END:VEVENT")[0]
        title, location, notes, start_raw, end_raw = "", "", "", "", ""
        for line in block.splitlines():
            line = line.strip()
            prop = line.split(":")[0].split(";")[0].upper()
            val  = line[line.index(":"):][1:] if ":" in line else ""
            if   prop == "SUMMARY":     title     = val.replace("\\,", ",").replace("\\;", ";")
            elif prop == "LOCATION":    location  = val.replace("\\,", ",").replace("\\;", ";")
            elif prop == "DESCRIPTION": notes     = val.replace("\\n", "\n").replace("\\,", ",").replace("\\;", ";")
            elif prop == "DTSTART":     start_raw = line
            elif prop == "DTEND":       end_raw   = line


        # Fall back to DESCRIPTION if SUMMARY is empty (common in weather feeds)
        if not title.strip():
            title = notes.split("\n")[0].strip() if notes else "Untitled Event"

        # Strip promo footer from notes (weather-in-calendar.com)
        if "🙌 Thanks for using" in notes:
            notes = notes[:notes.index("🙌 Thanks for using")].strip()
        if "View full weather report" in notes:
            notes = notes[:notes.index("View full weather report")].strip()

        # ── Step 1: Enrich title from notes BEFORE stripping emoji ──
        import re as _re
        if title and ("°" in title or any(e in title for e in ["☁️","🌤","⛅","🌦","🌧","🌨","🌩","☀️","🌥","🌫"])):
            hum  = _re.search(r"💧 Humidity (\d+%)", notes)
            wspd = _re.search(r"💨 Wind speed up to ([\d.]+ \w+)", notes)
            wdir = _re.search(r"🚩 from (\w+)", notes)
            extras = []
            if hum:  extras.append(f"💧 {hum.group(1)}")
            if wspd and wdir: extras.append(f"💨 {wspd.group(1)} {wdir.group(1)}")
            elif wspd:        extras.append(f"💨 {wspd.group(1)}")
            if extras:
                title = f"{title}  {'  '.join(extras)}"

        # ── Step 2: Clear notes for weather events — detail is in the agenda title ──
        if "°" in title or any(e in title for e in ["☁️","🌤","⛅","🌦","🌧","🌨","🌩","☀️","🌥","🌫"]):
            notes = ""
        if not start_raw:
            continue
        start_time, is_all_day = parse_ics_date(start_raw)
        if start_time is None:
            continue
        end_time, _ = parse_ics_date(end_raw) if end_raw else (start_time, is_all_day)
        if end_time is None:
            end_time = start_time
        event_dt = datetime.strptime(start_time, "%Y-%m-%dT%H:%M:%SZ")
        if not (start_filter <= event_dt <= end_filter):
            continue
        tags, seen = [], set()
        for tag in re.findall(r"\[([^\]\s]+)\]", (title + " " + notes).lower()):
            if tag not in seen:
                tags.append(tag); seen.add(tag)
        parsed.append({
            "id":           str(uuid.uuid4()).upper(),
            "title":        title,
            "location":     location,
            "startTime":    start_time,
            "endTime":      end_time,
            "notes":        notes,
            "tags":         tags,
            "calendarName": calendar_label,
            "isAllDay":     is_all_day,
            "isLocal":      False,
        })
    print(f"  {calendar_label}: {len(parsed)} event(s) in window.")
    return parsed


def perform_sync():
    start_filter, end_filter = get_date_bounds()
    print(f"Sync window: {start_filter.strftime('%Y-%m-%d')} to {end_filter.strftime('%Y-%m-%d')}\n")
    accounts = load_accounts()
    if not accounts:
        return False
    all_events = []
    for account in accounts:
        acct_type = account.get("type", "ics").lower()
        if acct_type == "metar":
            events = fetch_metar(account["url"], account["name"])
        elif acct_type == "taf":
            events = fetch_taf(account["url"], account["name"],
                               lat=account.get("lat"), lon=account.get("lon"))
        else:
            events = fetch_and_parse_feed(account["url"], account["name"], start_filter, end_filter)
        all_events.extend(events)
    if not all_events:
        print("\nNo events found across all accounts in this window.")
        return False
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(all_events, f, indent=4)
    print(f"\nSynced {len(all_events)} event(s) from {len(accounts)} account(s) to {OUTPUT_FILE}")
    return True


if __name__ == "__main__":
    success = perform_sync()
    sys.exit(0 if success else 1)