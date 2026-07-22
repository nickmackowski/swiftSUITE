"""
calendar_sync.py — swiftCALENDAR sync engine v2.7
─────────────────────────────────────────────────
Reads calendar account configs from calendar_accounts.json (written by
swiftCALENDAR's [A] Account Setup screen) and fetches ICS feeds for all
enabled accounts. Writes merged events to calendar.json.

METAR is persisted separately in metar_history.json (keyed by
"STATION|YYYY-MM-DD") so past observations survive future syncs instead of
being overwritten. History is capped at 6 months; anything older is pruned
each sync. TAF is a forecast and stays ephemeral — refreshed into
calendar.json on every sync like regular ICS events.

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
WEATHER_FILE  = "metar_history.json"   # persistent — upserted, never wholesale-overwritten
WEATHER_RETENTION_MONTHS = 6


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


def load_weather_history():
    if not os.path.exists(WEATHER_FILE):
        return {}
    try:
        with open(WEATHER_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"Warning: could not read {WEATHER_FILE}: {e}")
        return {}


def save_weather_history(history):
    try:
        with open(WEATHER_FILE, "w", encoding="utf-8") as f:
            json.dump(history, f, indent=4, sort_keys=True)
    except Exception as e:
        print(f"Warning: could not write {WEATHER_FILE}: {e}")


def prune_weather_history(history, months=WEATHER_RETENTION_MONTHS):
    """Drop METAR entries older than `months` calendar months. Keyed by
    'STATION|YYYY-MM-DD', so we just compare the date portion of the key."""
    now = datetime.now()
    # Calendar-correct month subtraction (not a fixed day count, so it doesn't
    # drift across months of different lengths)
    year  = now.year
    month = now.month - months
    while month <= 0:
        month += 12
        year  -= 1
    cutoff = now.replace(year=year, month=month)

    kept = {}
    dropped = 0
    for key, ev in history.items():
        try:
            day_str = key.split("|", 1)[1]
            day_dt  = datetime.strptime(day_str, "%Y-%m-%d")
        except (IndexError, ValueError):
            kept[key] = ev  # malformed key — keep rather than silently lose data
            continue
        if day_dt >= cutoff:
            kept[key] = ev
        else:
            dropped += 1
    if dropped:
        print(f"  Pruned {dropped} METAR entr{'y' if dropped == 1 else 'ies'} older than {months} months")
    return kept


def decode_wx_code(raw):
    """Decode a raw METAR/TAF body into a human-readable phrase for the
    detail view. The agenda/title keeps the raw code untouched — this is
    additive, shown only when a person drills into the event.

    Unrecognized tokens are skipped silently rather than echoed raw, since
    the untouched raw string is already preserved in the event title.

    Multi-token visibility fractions like "1 1/2SM" arrive as two separate
    tokens ("1" then "1/2SM"). Combining them correctly needs lookahead we
    don't do, so we report only the whole-mile part ("Visibility 1 statute
    mile") and drop the fraction rather than misreport it — a standalone
    fraction with no preceding whole number (e.g. plain "1/2SM") still
    reports normally.
    """
    WX_INTENSITY = {"-": "Light ", "+": "Heavy "}
    WX_DESCRIPTOR = {
        "MI": "shallow ", "PR": "partial ", "BC": "patches of ", "DR": "low drifting ",
        "BL": "blowing ", "SH": "showers of ", "TS": "thunderstorm with ", "FZ": "freezing ",
    }
    WX_PHENOM = {
        "DZ": "drizzle", "RA": "rain", "SN": "snow", "SG": "snow grains", "IC": "ice crystals",
        "PL": "ice pellets", "GR": "hail", "GS": "small hail", "UP": "unknown precipitation",
        "BR": "mist", "FG": "fog", "FU": "smoke", "VA": "volcanic ash", "DU": "widespread dust",
        "SA": "sand", "HZ": "haze", "PY": "spray", "PO": "dust/sand whirls", "SQ": "squall",
        "FC": "funnel cloud", "SS": "sandstorm", "DS": "duststorm",
    }
    SKY_COVER = {
        "SKC": "Clear", "CLR": "Clear", "NSC": "No significant cloud", "NCD": "No cloud detected",
        "FEW": "Few clouds", "SCT": "Scattered clouds", "BKN": "Broken clouds", "OVC": "Overcast",
    }

    parts = []
    tokens = raw.split()
    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        idx += 1

        # Timestamp and temp/dewpoint groups are surfaced elsewhere (title / Notes row)
        if re.match(r'^\d{6}Z$', tok) or re.match(r'^M?\d{2}/M?\d{2}$', tok):
            continue

        # Wind: ddd(or VRB) ss[Ggg]KT
        m = re.match(r'^(VRB|\d{3})(\d{2,3})(G(\d{2,3}))?KT$', tok)
        if m:
            direction, speed, _, gust = m.groups()
            if direction == "000" and not gust:
                parts.append("Calm")
            else:
                dirtext = "Variable" if direction == "VRB" else f"{direction}\u00b0"
                gusttext = f", gusts {gust}kt" if gust else ""
                parts.append(f"Wind {dirtext} at {speed}kt{gusttext}")
            continue

        # Visibility: P6SM, 10SM, 1/2SM
        m = re.match(r'^(P)?(\d+(?:/\d+)?)SM$', tok)
        if m:
            plus, val = m.groups()
            # Guard against the split "N N/DSM" whole+fraction case (e.g. "1 1/2SM" arrives
            # as two tokens). If the immediately preceding token was a bare integer, this
            # fraction is its continuation — report the whole-mile part only and drop the
            # fraction rather than misreport it (see docstring).
            is_bare_fraction = "/" in val
            prev_tok = tokens[idx - 2] if idx >= 2 else None
            prev_is_bare_int = bool(prev_tok and re.match(r'^\d+$', prev_tok))
            if is_bare_fraction and prev_is_bare_int:
                unit = "mile" if prev_tok == "1" else "miles"
                parts.append(f"Visibility {prev_tok} statute {unit}")
                continue
            suffix = "+" if plus else ""
            parts.append(f"Visibility {val}{suffix} statute miles")
            continue
        if tok == "CAVOK":
            parts.append("Ceiling/visibility OK (10km+, no significant cloud/weather)")
            continue
        if re.match(r'^\d{4}$', tok) and tok != "0000":
            # Bare 4-digit visibility in meters (non-US reports)
            meters = int(tok)
            parts.append("Visibility 10km+" if meters >= 9999 else f"Visibility {meters}m")
            continue

        # Sky cover: FEW/SCT/BKN/OVC + 3-digit height (x100ft), optional CB/TCU suffix
        m = re.match(r'^(FEW|SCT|BKN|OVC)(\d{3})(CB|TCU)?$', tok)
        if m:
            cover, height, cloud_type = m.groups()
            height_ft = int(height) * 100
            typetext = f" ({'cumulonimbus' if cloud_type == 'CB' else 'towering cumulus'})" if cloud_type else ""
            parts.append(f"{SKY_COVER[cover]} at {height_ft:,}ft{typetext}")
            continue
        if tok in SKY_COVER:
            parts.append(SKY_COVER[tok])
            continue
        m = re.match(r'^VV(\d{3})$', tok)
        if m:
            parts.append(f"Vertical visibility {int(m.group(1)) * 100:,}ft (sky obscured)")
            continue

        # Altimeter: A2992 (inHg) or Q1013 (hPa)
        m = re.match(r'^A(\d{4})$', tok)
        if m:
            parts.append(f"Altimeter {int(m.group(1))/100:.2f} inHg")
            continue
        m = re.match(r'^Q(\d{4})$', tok)
        if m:
            parts.append(f"Altimeter {m.group(1)} hPa")
            continue

        # Weather phenomena: optional intensity/vicinity + descriptor(s) + phenomenon(s)
        wx_tok = tok
        prefix = ""
        if wx_tok.startswith("VC"):
            prefix = "In the vicinity: "
            wx_tok = wx_tok[2:]
        elif wx_tok and wx_tok[0] in "-+":
            prefix = WX_INTENSITY[wx_tok[0]]
            wx_tok = wx_tok[1:]
        codes = [wx_tok[i:i+2] for i in range(0, len(wx_tok), 2)]
        if wx_tok and len(wx_tok) % 2 == 0 and all(c in WX_DESCRIPTOR or c in WX_PHENOM for c in codes):
            desc = "".join(WX_DESCRIPTOR.get(c, "") for c in codes)
            phen = " and ".join(WX_PHENOM[c] for c in codes if c in WX_PHENOM)
            if phen:
                parts.append(f"{prefix}{desc}{phen}".strip().capitalize())
                continue

        # Unrecognized token — skip silently, raw string already preserved in title

    return " \u00b7 ".join(parts)


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
            "id":             str(uuid.uuid4()).upper(),
            "title":          title,
            "location":       station_id,
            "startTime":      start,
            "endTime":        end,
            "notes":          temp_suffix,
            "tags":           [],
            "calendarName":   calendar_label,
            "isAllDay":       True,
            "isLocal":        False,
            "decodedWeather": decode_wx_code(metar_short),
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


def sync_metar_account(station_id, calendar_label, history):
    """Fetch today's/yesterday's METAR and upsert into the persistent history
    dict, keyed by station+day. Days not re-fetched this run are left alone —
    this is what makes past observations survive future syncs."""
    for ev in fetch_metar(station_id, calendar_label):
        day_key = ev["startTime"][:10]  # YYYY-MM-DD
        history[f"{station_id.upper()}|{day_key}"] = ev


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
        "id":             str(uuid.uuid4()).upper(),
        "title":          full_title,
        "location":       station_id,
        "startTime":      tmrw_start,
        "endTime":        tmrw_end,
        "notes":          temp_f_str,   # red display in Swift agenda, same as METAR
        "tags":           [],
        "calendarName":   calendar_label,
        "isAllDay":       True,
        "isLocal":        False,
        "decodedWeather": decode_wx_code(taf_line),
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

    weather_history = load_weather_history()
    weather_touched = False
    all_events = []

    for account in accounts:
        acct_type = account.get("type", "ics").lower()
        if acct_type == "metar":
            # METAR is persisted separately (metar_history.json) so past
            # observations survive future syncs instead of being overwritten.
            sync_metar_account(account["url"], account["name"], weather_history)
            weather_touched = True
        elif acct_type == "taf":
            # Forecast — always ephemeral, refreshed each sync
            all_events.extend(fetch_taf(account["url"], account["name"],
                                         lat=account.get("lat"), lon=account.get("lon")))
        else:
            all_events.extend(fetch_and_parse_feed(account["url"], account["name"],
                                                     start_filter, end_filter))

    if weather_touched:
        weather_history = prune_weather_history(weather_history)
        save_weather_history(weather_history)
        print(f"Weather history: {len(weather_history)} day(s) on file in {WEATHER_FILE}")

    if not all_events and not weather_touched:
        print("\nNo events found across all accounts in this window.")
        return False

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(all_events, f, indent=4)
    print(f"\nSynced {len(all_events)} event(s) from {len(accounts)} account(s) to {OUTPUT_FILE}")
    return True


if __name__ == "__main__":
    success = perform_sync()
    sys.exit(0 if success else 1)