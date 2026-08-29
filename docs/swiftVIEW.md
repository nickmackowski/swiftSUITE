# swiftVIEW

A read-only glance companion — a small window showing today's and tomorrow's calendar events, weather, and your notes together in one list. Click anything to see its full details in a popup; nothing here can be edited or deleted. It exists purely to answer "what's going on" at a glance, not as a second way to manage your calendar or notes.

<!-- add a real screenshot link here, matching the other docs' style, e.g.: -->
<!-- <img width="412" height="674" alt="image" src="https://github.com/user-attachments/assets/REPLACE_ME" /> -->

---

## What It Shows

**Today & Tomorrow** — two sections, each combining:
- **Weather** — one row per configured METAR station for today (the most recent observation), one row per configured TAF station for tomorrow (the forecast for that day). Always pinned first in its section regardless of alphabetical order, styled in the suite's own weatherBlue. Row text is a short glanceable summary (visibility + Fahrenheit temperature) rather than the raw METAR/TAF code, which never fit cleanly in a compact list row.
- **Due-date notes** — any note with a due date landing on that day, pulled directly from swiftNOTES' own due-date field, styled in dueYellow. Clicking one opens the actual note, not a separate synthetic entry.
- **Calendar events** — everything else on the calendar for that day, each styled in its own account's configured color (set in swiftCALENDAR's account setup) — except local events, which always show in localRed, and birthdays, which always show in birthdayPurple, matching swiftCALENDAR's own color-priority order exactly. Already-finished events for today are shown dimmed rather than hidden, so the day's full schedule stays visible.

**Notes** — every non-archived note, title only. Alternating rows get swiftNOTES' own greenbar striping for visual separation — the one place in this window that still uses the original pill styling rather than a dot, since notes don't have an individual "color" the way calendar entries do.

---

## Detail Popups

Click any row to open a small popup with that item's full information — read-only throughout, matching the whole point of this app.

**Notes** — name, date created, due date (if any), tags (if any), then the note body itself, scrollable since it can run long. Timestamps embedded in the body by swiftNOTES (added automatically on creation and again on every append) render as a small inline clock icon plus a clean time label, instead of the raw `[MM/dd/yy hh:mm a]` bracket text.

**Weather** — calendar name, date, the real observed/issued time (parsed from the raw METAR/TAF text itself, not just "all day"), the airport's full name and city (from `known_airports.json`), the actual raw METAR/TAF code, the decoded plain-English conditions, temperature in Celsius with the Fahrenheit conversion in red alongside it, and — METAR only — a barometric pressure trend arrow comparing against the most recent prior day's reading. TAF gets everything except the pressure trend, since a forecast issued once has no "current reading" to trend against.

---

## Refresh Rate

One 20-second timer, matching swiftSYSINFO's own "everything else" cadence — re-reads every data source and rebuilds the list. There's no editing anywhere in this app, so there's none of swiftSTICKY's "don't refresh out from under an in-progress edit" concern; it's always safe to just reload.

---

## Right-Click Menu

- **Bigger / Smaller** — same rebuild-the-whole-window-at-a-new-scale approach as swiftSYSINFO, for the same reason: rows are laid out at absolute positions computed once, not continuously recalculated.
- **Reverse Colors** — toggles light/dark styling
- **Dot Style** — swaps the calendar section's colored pills for small status dots (same size as swiftSYSINFO's own), if you prefer the quieter look. Defaults on.
- **Quit**

Each detail popup has its own matching menu — Bigger / Smaller / Reverse Colors apply app-wide and rebuild the main window too, and **Close** shuts just that one popup rather than quitting the whole app.

---

## Data Sources

swiftVIEW is entirely self-locating, like the other companion apps — it finds its neighbors relative to its own position on disk, no configuration needed anywhere. It reads directly from:

| File | From | What |
|------|------|------|
| `swiftNOTES/notes.json` | swiftNOTES | Note titles, due dates, tags, dates created (plaintext) and encrypted bodies, decrypted on demand when a note is opened |
| `swiftCALENDAR/calendar.json` | swiftCALENDAR | Regular events and TAF forecasts |
| `swiftCALENDAR/metar_history.json` | swiftCALENDAR | METAR observations |
| `swiftCALENDAR/local_events.json` | swiftCALENDAR | Locally-created events |
| `swiftCALENDAR/known_airports.json` | swiftCALENDAR | Airport names and locations for the weather detail popup |
| `swiftCALENDAR/calendar_accounts.json` | swiftCALENDAR | Per-calendar colors |
| `swiftCONTACTS/contacts.json` | swiftCONTACTS | Birthdays — computed live on every refresh, exactly like swiftCALENDAR does it, never written anywhere as a calendar entry |

Notes decryption uses the same swiftCORE session swiftNOTES itself relies on — no separate login, but also no access without an active session, same as swiftNOTES.

---

## Requirements

- macOS 12 (Monterey) or later
- Xcode Command Line Tools (`xcode-select --install`)

---

## Building

Swift Package Manager project, built as a universal binary (arm64 + x86_64) via its own `build.sh`:

```bash
cd swiftVIEW
./build.sh
```

Or via swiftADMIN (auto-detected by the presence of `Package.swift`):

```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps, or [2] to build swiftVIEW specifically
```

---

Part of the [swiftSUITE](../README.md) collection. Launchable directly from [swiftCT](swiftCT.md)'s Utilities menu.
