# swiftCALENDAR

swiftCALENDAR is a calendar app that syncs with any ICS/CalDAV feed and optionally displays live aviation weather (METAR and TAF) alongside your events. It provides a month grid view with a daily agenda, supports adding local events that persist across syncs, and layers in three live overlays computed from the rest of the suite — birthdays from swiftCONTACTS, due dates from swiftNOTES, and remotely-captured entries sent by email or text.

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/0141a8cd-0fcb-44b1-9c4f-d1a0ff0a4412" />

---

## What It Does

- Displays a monthly calendar grid with event density indicators and a bold-white `*` marking today
- Shows a daily agenda for the selected date
- Syncs with any number of ICS/CalDAV calendar feeds
- Fetches live METAR weather observations and TAF forecasts for any ICAO airport, with the real airport name and city decoded in the detail view
- Supports locally created events that are not synced back to any external service
- Overlays recurring birthdays computed live from swiftCONTACTS — nothing is stored in swiftCALENDAR itself
- Overlays due-date reminders computed live from swiftNOTES, including an automatic 3-day-advance heads-up
- Picks up calendar entries sent remotely by email or text (see [Remote Calendar Entries](#remote-calendar-entries) below)
- Color-codes events by calendar account

---

## Main Workspace

```
CALENDAR: 79 Events Loaded                            ● Last Sync: 08-03-26 03:41 PM
79 Events from 6 Calendars  [R] to sync
```

The month grid shows the current month. Today's date carries a small bold-white `*` next to the day number — a color-independent marker that stays easy to spot regardless of whatever event color that day also has. Days with events appear brighter than days without. Below the grid, the agenda shows all events for the currently highlighted date.

---

## Navigation

| Key | Action |
|-----|--------|
| `←` / `→` | Move one day |
| `↑` / `↓` | Move one week |
| `<` or `,` | Previous month |
| `>` or `.` | Next month |
| `ENTER` | View event detail for selected day |
| `R` | Sync calendars (also checks for remote entries — see below) |
| `E` | Add a new local event |
| `A` | Account setup (add/remove calendar sources) |

---

## Account Setup

Press `A` to open the Calendar Account Setup screen. This is where you add calendar sources.

```
↑/↓: Select | ENTER: Edit | A: Add | D: Delete | X: Toggle | ESC: Back
```

At any prompt in the add/edit flow, type `esc` and press Enter, or press Escape and press Enter, to cancel and back out with nothing changed. (A genuine Escape keypress alone doesn't submit until you also press Enter — canonical text input works that way regardless of what you type.)

Two account types are supported:

### ICS Feed
Any public or private ICS/CalDAV URL. Compatible with:
- iCloud (use the public calendar share link)
- Outlook / Office 365
- Google Calendar (use the ICS URL from calendar settings)
- Any standard CalDAV feed

You'll be asked to pick a color for ICS accounts (see [Color Coding](#color-coding) below).

### Aviation Weather (METAR + TAF)
One combined setup for live aviation weather. Enter a single ICAO airport code (e.g. `KCLT`) and swiftCALENDAR creates **both** a METAR account and a TAF account from it automatically — no need to add them separately.

```
Airport Code (e.g. KCLT, KRDU): KRDU
Found Raleigh-Durham International Airport (Raleigh/Durham, NC) — lat/lon auto-filled.
```

If the airport is in the pre-seeded `known_airports.json` list (439 U.S. airports), its latitude/longitude is filled in automatically for the NWS temperature lookup. If it isn't recognized, you'll be prompted to enter latitude/longitude manually (or just press Enter to skip — the weather data still works, you just won't get the NWS high/low temp).

There's no color prompt for weather accounts — METAR and TAF always render in the reserved blue regardless of anything you'd pick, so the app skips asking (see [Color Coding](#color-coding)).

Adding an account of either type triggers an immediate sync, so new data shows up right away instead of waiting for the next `[R]` press.

---

## Color Coding

Each ICS calendar account can be assigned one of seven colors:

| # | Color |
|---|-------|
| 1 | Cyan |
| 2 | Green |
| 3 | Magenta |
| 4 | Orange |
| 5 | Pink |
| 6 | Teal |
| 7 | Mint |

Four colors are reserved and never appear in the picker, since each one is already permanently assigned to something else on the calendar:

| Color | Reserved for |
|-------|---------------|
| Red | Local events |
| Blue | METAR/TAF weather |
| Yellow | Due-date reminders |
| Purple | Birthdays |

Assign colors for ICS accounts in `[A] Account Setup`. The color appears on the calendar name prefix in the agenda and on date numbers in the month grid when that calendar has events on a given day.

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
| `E` | Edit event — local events only |
| `D` | Delete this event |
| `A` | Account setup |
| `ESC` | Back to calendar |

**Important — Delete doesn't always mean permanently gone.** Delete is only permanent for genuine local events (ones you typed in directly, or that arrived via remote capture — see below). Birthday and due-date entries are *computed live* every time swiftCALENDAR loads — nothing about them is stored in this app at all. Pressing Delete on one of those removes it from the screen only until the next sync or relaunch, at which point it recomputes and comes right back. To actually get rid of a birthday, edit or remove it in swiftCONTACTS. To get rid of a due-date reminder, clear or complete the note's due date in swiftNOTES.

---

## Birthday Overlay

swiftCALENDAR reads `birthdayMonthDay` directly out of swiftCONTACTS' `contacts.json` and computes recurring all-day birthday events live — every launch, for a window of roughly three years back and three years forward. Nothing is ever written back to `contacts.json`, and no birthday data is stored anywhere inside swiftCALENDAR itself.

Birthdays always render in **purple**, both in the month grid and the agenda, and the event title is formatted as `🎂 [Name]'s Birthday`.

---

## Due-Date Overlay

swiftCALENDAR reads `dueDate` directly out of swiftNOTES' `notes.json` for every note that has one set and isn't archived, computing two things live on every launch:

- The due-date marker itself, on the date the note is due
- An automatic reminder titled `Reminder: [Note Title] due in 3 days`, three days ahead of it

Both render in **yellow**. Like birthdays, none of this is stored in swiftCALENDAR — it's recomputed fresh from `notes.json` every time.

---

## Remote Calendar Entries

swiftCALENDAR shares a capture pipeline with swiftNOTES — the same "remote send inbox" you already use to text or email yourself notes can also create real calendar events, using a subject-line prefix to tell the two apart:

- **`c:`** — creates a calendar event
- **`n:`** or no prefix — creates a note (unchanged, existing behavior)

A `c:` message needs one line in the body giving the date and time together:

```
Subject: c: Dentist appointment

Date: 8/15 3:00p
```

- `Date:` accepts `M/D`, `M/D/YY`, and time formats like `3:00p`, `3p`, or `15:00`
- The event always lasts exactly **1 hour** — no separate end time needed
- Anything else in the body becomes the event's notes field
- If the `Date:` line is missing or can't be parsed, the message is skipped for calendar purposes rather than guessing — check the logs if a `c:` message doesn't show up (see [Known Limitations](#known-limitations))

Remote entries created this way are genuine local events (`isLocal: true`, calendar name "Local") — they behave exactly like something you typed in directly with `[E]`, including that Delete on them is permanent.

**Trigger:** unlike swiftNOTES, swiftCALENDAR does not check for remote entries automatically on launch — that runs alongside the manual `[R]` sync instead (and when you add a new calendar account), not on its own background schedule. If you're using swiftNOTES regularly, remote `c:` entries will usually already be waiting in `local_events.json` by the time you open swiftCALENDAR anyway, since swiftNOTES' own launch-check processes the same inbox and routes `c:` messages the same way. See [Known Limitations](#known-limitations) for why this is deliberately synchronous rather than automatic.

---

## Understanding METAR and TAF

### METAR — Current Conditions

A METAR is a real-time weather observation at an airport, updated every 30–60 minutes.

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

Cloud coverage: CLR = Clear, FEW = 1–2 oktas, SCT = Scattered, BKN = Broken, OVC = Overcast

### TAF — Forecast

A TAF is a 24–30 hour forecast using the same format as a METAR. swiftCALENDAR extracts the FM (From) group for tomorrow morning and displays it as a single line.

`FM190300 24004KT P6SM FEW050 BKN250` = From the 19th at 03:00Z, wind 240° at 4 knots, visibility greater than 6 miles, few clouds at 5,000 ft.

### Location Decoding

Open the detail view on any METAR or TAF event and the Location row shows more than the bare ICAO code — it looks up the real airport name and city from `known_airports.json` and appends it in brackets:

```
Location    KCLT [Charlotte Douglas International Airport | Charlotte, NC]
```

The raw ICAO code stays plain white, since it's literally what's in the data. The bracketed portion is red — the same convention used for the Fahrenheit temperature conversion elsewhere in this view — meaning "derived, not literally present in the raw feed." If the ICAO code isn't in the pre-seeded list, the Location row just falls back to showing the bare code.

`known_airports.json` ships pre-seeded with 439 U.S. airports (schema: `ICAO -> {display, airportName, iata, lat, lon}`). There's no in-app tool to add more — it's meant to be hand-edited directly if you need an airport that isn't already there. Open the file, copy the format of an existing entry, and add yours.

---

## Sync

Press `R` to sync. This runs three things in sequence:

1. `calendar_sync.py` — reads `calendar_accounts.json`, fetches every enabled ICS/METAR/TAF account, writes the result to `calendar.json`
2. The shared remote-capture script — checks your configured send-inbox for any `c:`/`n:` messages waiting (see [Remote Calendar Entries](#remote-calendar-entries))
3. Every overlay gets recomputed — birthdays, due-dates, local events, and weather history are all re-merged back in, since step 1 fully rewrites `calendar.json` and would otherwise wipe them out

There's no automatic background sync — swiftCALENDAR only ever syncs when you press `[R]`, or when you add/edit a calendar account (which triggers an immediate sync for just that change). This is a deliberate design choice: swiftCALENDAR is meant to be a quick-glance overlay tool, not a full calendar replacement with two-way sync.

---

## The calendar_sync.py Script

`calendar_sync.py` is the sync engine that runs when you press `[R]`. It lives directly in the `swiftCALENDAR` folder (not `source_code/`) and reads account configurations from `calendar_accounts.json`.

To run it manually:

```bash
cd swiftCALENDAR
python3 calendar_sync.py
```

Requirements: Python 3.9+, no additional packages needed.

All-day events (both regular ICS all-day entries and TAF's "tomorrow" forecast) are internally timestamped at **noon UTC**, not midnight — this is deliberate. Midnight UTC rolls back to the evening of the previous day in any negative-UTC-offset timezone (US Eastern, Central, etc.), which shifted every all-day event a day earlier than it should have shown. Noon UTC never crosses a day boundary for any realistic timezone, so this is the fix, not a bug to work around.

---

## Known Limitations

- **No live-animating sync spinner.** `[R]` shows a plain "Syncing calendar..." status line rather than an animated one. This was tried and reverted — running the sync on a background thread (the mechanism needed for a live animation) reliably broke keyboard input on the Account Setup screen, regardless of whether the background sync ran at launch or was triggered mid-session by `[R]`. The exact low-level cause was never fully isolated; the safe, synchronous version is what's shipped. The brief blocking pause during `[R]` is the accepted tradeoff.
- **Remote entries aren't checked automatically on launch**, unlike swiftNOTES — see [Remote Calendar Entries](#remote-calendar-entries) above for why, and why it's rarely a practical gap if you also use swiftNOTES regularly.
- **Deleting a birthday or due-date entry from the calendar is temporary**, not permanent — see the note in [Event Detail](#event-detail) above.
- **No live-updating clock in the header.** Like the rest of the suite, the time in the header only refreshes on keystroke, not continuously. This is a known, deliberate suite-wide limitation, not specific to swiftCALENDAR.

---

## Tips

- Add Aviation Weather as your first account so weather appears at the top of each day's agenda
- Use `[R]` after making changes to `calendar_accounts.json` directly to immediately see the effect
- Local events are a great way to add personal reminders that you don't want in your shared iCloud or Outlook calendar
- If you use swiftNOTES' remote capture already, `c:` calendar entries are essentially free — same inbox, same setup, just a different subject prefix
- If an airport's METAR/TAF location isn't decoding in the detail view, check whether its ICAO code is in `known_airports.json` — if not, add it by hand following the existing format
