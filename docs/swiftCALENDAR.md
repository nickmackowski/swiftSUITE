# swiftCALENDAR

swiftCALENDAR is a calendar app that syncs with any ICS/CalDAV feed and optionally displays live aviation weather (METAR and TAF) alongside your events. It provides a month grid view with a daily agenda and supports adding local events that persist across syncs.

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/0141a8cd-0fcb-44b1-9c4f-d1a0ff0a4412" />

---

## What It Does

- Displays a monthly calendar grid with event density indicators
- Shows a daily agenda for the selected date
- Syncs with any number of ICS/CalDAV calendar feeds
- Fetches live METAR weather observations and TAF forecasts for any ICAO airport
- Supports locally created events that are not synced back to any external service
- Color-codes events by calendar account

---

## Main Workspace

```
CALENDAR: 67 Events Loaded                            ● Last Sync: 07-17-26 09:21 AM
67 Events from 2 Calendars  [R] to sync
```

The month grid shows the current month with today highlighted in green. Days with events appear brighter than days without. Below the grid, the agenda shows all events for the currently highlighted date.

---

## Navigation

| Key | Action |
|-----|--------|
| `←` / `→` | Move one day |
| `↑` / `↓` | Move one week |
| `<` or `,` | Previous month |
| `>` or `.` | Next month |
| `ENTER` | View event detail for selected day |
| `R` | Sync calendars |
| `E` | Add a new local event |
| `A` | Account setup (add/remove calendar sources) |

---

## Account Setup

Press `A` to open the Calendar Account Setup screen. This is where you add calendar sources.

Three account types are supported:

### ICS Feed
Any public or private ICS/CalDAV URL. Compatible with:
- iCloud (use the public calendar share link)
- Outlook / Office 365
- Google Calendar (use the ICS URL from calendar settings)
- Any standard CalDAV feed

### METAR (Aviation Weather)
Fetches the latest METAR observation for an ICAO airport code. Creates a single all-day event on today's date showing current conditions.

```
(METAR CLT)  181552Z 22008KT 10SM FEW045 BKN250 28/17 A2998  [82°F/63°F]
```

The Fahrenheit temperature conversion is shown in red. See [Understanding METAR and TAF](#understanding-metar-and-taf) below.

### TAF (Aviation Forecast)
Fetches the Terminal Aerodrome Forecast for an ICAO airport code. Creates a single all-day event on tomorrow's date showing the forecast conditions for that morning. If latitude and longitude are provided, the NWS high/low temperature forecast is appended in red.

```
(TAF CLT)  24004KT P6SM FEW050 BKN250 27/23  [85°F/68°F]
```

Together, METAR and TAF create a rolling 24-hour aviation weather window directly in your agenda.

---

## Color Coding

Each calendar account can be assigned one of seven colors:

| # | Color |
|---|-------|
| 1 | Cyan |
| 2 | Green |
| 3 | Yellow |
| 4 | Magenta |
| 5 | Orange |
| 6 | Blue |
| 7 | Purple |

Red is reserved for locally created events and cannot be assigned to an account.

Assign colors in `[A] Account Setup`. The color appears on the calendar name prefix in the agenda and on date numbers in the month grid when that calendar has events on a given day.

---

## Adding Local Events

Press `E` from the month view to add an event. The date of the currently highlighted day is pre-filled.

You will be prompted for:
1. **Title** — event name
2. **Date** — pre-filled from selected day, press Enter to accept or type a new date
3. **All day?** — yes or no
4. **Start time / End time** — if not all-day
5. **Notes** — optional

Local events are saved to `local_events.json` separately from synced events. They are never overwritten by a sync and persist indefinitely. Local events appear in the agenda with a red `(Local)` prefix.

---

## Event Detail

Press `ENTER` on any day with events, then select an event by number to open the detail view.

| Key | Action |
|-----|--------|
| `T` | Add a new event |
| `D` | Delete this event |
| `A` | Account setup |
| `ESC` | Back to calendar |

---

## Sync

Press `R` to run `calendar_sync.py` and refresh all calendar data. The sync:

1. Reads account configurations from `calendar_accounts.json`
2. Fetches each enabled account (ICS, METAR, or TAF)
3. Filters events to a rolling window covering last month through next month
4. Writes results to `calendar.json`
5. Reloads the calendar view

The calendar also auto-syncs every 15 minutes while the app is open.

---

## Understanding METAR and TAF

### METAR — Current Conditions

A METAR is a real-time weather observation at an airport, updated every 30-60 minutes.

**Example:** `KCLT 181552Z 22008KT 10SM FEW045 BKN250 28/17 A2998`

| Token | Meaning |
|-------|---------|
| `KCLT` | Airport — Charlotte Douglas |
| `181552Z` | 18th at 15:52 UTC |
| `22008KT` | Wind from 220° at 8 knots |
| `10SM` | Visibility 10 statute miles |
| `FEW045` | Few clouds at 4,500 ft |
| `BKN250` | Broken layer at 25,000 ft |
| `28/17` | Temp 28°C / Dewpoint 17°C |
| `A2998` | Altimeter 29.98 inHg |

Cloud coverage: CLR = Clear, FEW = 1-2 oktas, SCT = Scattered, BKN = Broken, OVC = Overcast

### TAF — Forecast

A TAF is a 24-30 hour forecast using the same format as a METAR. swiftCALENDAR extracts the FM (From) group for tomorrow morning and displays it as a single line.

`FM190300 24004KT P6SM FEW050 BKN250` = From the 19th at 03:00Z, wind 240° at 4 knots, visibility greater than 6 miles, few clouds at 5,000 ft.

---

## The calendar_sync.py Script

`calendar_sync.py` is the sync engine that runs when you press `[R]`. It lives in the `swiftCALENDAR` folder and reads account configurations from `calendar_accounts.json`.

To run it manually:

```bash
cd swiftCALENDAR
python3 calendar_sync.py
```

Requirements: Python 3.9+, no additional packages needed.

---

## Tips

- Add METAR and TAF as the first accounts so weather appears at the top of each day's agenda
- Use `[R]` after making changes to `calendar_accounts.json` to immediately see the effect
- Local events are a great way to add personal reminders that you don't want in your shared iCloud or Outlook calendar
