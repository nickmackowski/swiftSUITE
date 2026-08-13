# swiftCALENDAR

swiftCALENDAR is a calendar app that syncs with any ICS/CalDAV feed and optionally displays live aviation weather (METAR and TAF) alongside your events. It provides a month grid view with a daily agenda, supports adding local events that persist across syncs, and layers in three live overlays computed from the rest of the suite — birthdays from swiftCONTACTS, due dates from swiftNOTES, and remotely-captured entries sent by email or text.

<img width="2314" height="1688" alt="image" src="https://github.com/user-attachments/assets/28c2d2f6-825c-4cf9-b058-95d5d33a18b5" />


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
79 Events from 6 Calendars
```

On launch, a static placeholder grid appears immediately — correct day numbers and today's marker, but no event data — with a live animated spinner status line below it. This stays up for the whole sync; once it finishes, the screen redraws once with real data. See [Sync](#sync) below for why it works this way.

Today's date carries a small bold-white `*` next to the day number — a color-independent marker that stays easy to spot regardless of whatever event color that day also has. Days with events appear brighter than days without. Below the grid, the agenda shows all events for the currently highlighted date — weather entries (METAR/TAF) always sort to the top of the agenda, regardless of how many there are.

---

## Navigation

| Key | Action |
|-----|--------|
| `←` / `→` | Move one day |
| `↑` / `↓` | Move one week |
| `<` or `,` | Previous month |
| `>` or `.` | Next month |
| `ENTER` | View event detail for selected day |
| `E` | Add a new local event |
| `A` | Account setup (add/remove calendar sources) |

There's no manual refresh key — quit and relaunch to get fresh data. See [Sync](#sync) below for why.

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

If the airport is in the pre-seeded `known_airports.json` list (over 400 airports — mostly US, with a good number of major international ones too, see [the full list](#appendix-known-airports)), its latitude/longitude is filled in automatically. If it isn't recognized, you'll be prompted to enter latitude/longitude manually (or just press Enter to skip). Note that the NWS high/low temperature lookup specifically only has data for US locations — for an international airport, lat/lon still auto-fills correctly, but the NWS temp line just won't appear, since the National Weather Service doesn't cover locations outside the US. Everything else (the METAR/TAF data itself, location-name decoding) works the same regardless of country.

There's no color prompt for weather accounts — METAR and TAF always render in the reserved blue (see [Color Coding](#color-coding)). The account list on this screen shows `Color: Blue` for these accounts.

Adding a new account saves it immediately, but its data won't appear until the next launch — quit and relaunch swiftCALENDAR to pull in the new feed. The easiest way to do this is just pop over to another app and come back to calendar.  See [Sync](#sync) below for why.

Deleting a METAR account prompts a follow-up: whether to also delete that station's historical data. METAR observations persist in a separate file that survives across syncs (unlike regular calendar data, which fully refreshes each time) — say yes to also clear out that station's history, or no to keep it around for reference. TAF data doesn't need this same prompt; it's already covered by the regular per-launch refresh.

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
- **`n:`** — creates a note (recommended convention — a subject with no prefix at all still works too, kept for backward compatibility, but `n:` is the standard going forward; see swiftNOTES' own README for details)

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

**Trigger:** swiftCALENDAR checks for remote entries automatically every time it launches, bundled into the same sync as your ICS/METAR/TAF accounts (see [Sync](#sync) below) — matching swiftNOTES' own launch-check. There's no manual trigger for this or anything else; quit and relaunch to check again.

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

`known_airports.json` ships pre-seeded with over 400 airports (schema: `ICAO -> {display, airportName, iata, lat, lon}`) — see the [full list](#appendix-known-airports) at the end of this document. There's no in-app tool to add more — it's meant to be hand-edited directly if you need an airport that isn't already there. Open the file, copy the format of an existing entry, and add yours.

---

## Sync

swiftCALENDAR syncs automatically every time it launches — there's no manual refresh key. To get fresh data at any point, quit and relaunch.

On launch, this runs in sequence:

1. A static placeholder grid appears immediately — correct day numbers and today's marker, no event data yet — with a live animated spinner underneath. You're never staring at a truly blank screen while waiting on the network, but this isn't last session's data either — it's a generic placeholder shown fresh every launch
2. `calendar_sync.py` runs — reads `calendar_accounts.json`, fetches every enabled ICS/METAR/TAF account, writes the result to `calendar.json`
3. The shared remote-capture script runs next — checks your configured send-inbox for any `c:`/`n:` messages waiting (see [Remote Calendar Entries](#remote-calendar-entries)), same placeholder-and-spinner screen stays up
4. Every overlay gets recomputed — birthdays, due-dates, local events, and weather history are all re-merged back in, since step 2 fully rewrites `calendar.json` and would otherwise wipe them out
5. The screen redraws once with real data, no keypress needed

Adding or editing a calendar account also saves immediately, but doesn't trigger its own sync — the new data shows up on your next relaunch, same as everything else.

This is a deliberate design choice on two levels. First, swiftCALENDAR is meant to be a quick-glance overlay tool, not a full calendar replacement with two-way sync or continuous background polling. Second, and more specifically: an earlier version *did* try a background-thread-based sync that could run mid-session (triggered by a manual refresh key) — and that approach reliably broke keyboard input on the Account Setup screen, no matter how it was scoped. The launch-only, no-background-thread version documented here is the one that was actually proven safe through extensive testing — see [The calendar_sync.py Script](#the-calendar_syncpy-script) below for the technical reason a live spinner animation is possible here despite that constraint.

---

## The calendar_sync.py Script

`calendar_sync.py` is the sync engine that runs automatically every time swiftCALENDAR launches (see [Sync](#sync) above). It lives directly in the `swiftCALENDAR` folder (not `source_code/`) and reads account configurations from `calendar_accounts.json`.

To run it manually:

```bash
cd swiftCALENDAR
python3 calendar_sync.py
```

Requirements: Python 3.9+, no additional packages needed.

**How the spinner animates without a background thread:** the sync script is started as a subprocess without blocking on it, and swiftCALENDAR itself polls whether that subprocess is still running in a loop on the main thread — redrawing a spinner frame each pass — until it finishes. This is different from simply blocking on the subprocess (which would freeze the animation, not just the sync), and also different from running the wait on a background thread (which is what actually broke Account Setup in earlier testing — see [Sync](#sync) above). The result: a genuinely live animation, with the same background-thread risk that caused real problems avoided entirely.

All-day events (both regular ICS all-day entries and TAF's "tomorrow" forecast) are internally timestamped at **noon UTC**, not midnight — this is deliberate. Midnight UTC rolls back to the evening of the previous day in any negative-UTC-offset timezone (US Eastern, Central, etc.), which shifted every all-day event a day earlier than it should have shown. Noon UTC never crosses a day boundary for any realistic timezone, so this is the fix, not a bug to work around.

---

## Known Limitations

- **No manual refresh key.** To get fresh data at any point — new events, a newly-added account, remote entries — quit and relaunch. This was a deliberate trade after extensive testing: an earlier version allowed a manual refresh triggered mid-session, but that specific pattern (a background thread waiting on the sync) reliably broke Account Setup's keyboard input. Launch-only sync is the version proven safe. See [Sync](#sync) above for the full story.
- **Deleting a birthday or due-date entry from the calendar is temporary**, not permanent — see the note in [Event Detail](#event-detail) above.
- **No live-updating clock in the header.** Like the rest of the suite, the time in the header only refreshes on keystroke, not continuously. This is a known, deliberate suite-wide limitation, not specific to swiftCALENDAR.

---

## Tips

- Add Aviation Weather as your first account so weather appears at the top of each day's agenda (weather also always sorts first regardless of order, so this is really just about the account list being tidy)
- After editing `calendar_accounts.json` directly, quit and relaunch to see the effect — there's no manual sync key
- Local events are a great way to add personal reminders that you don't want in your shared iCloud or Outlook calendar
- If you use swiftNOTES' remote capture already, `c:` calendar entries are essentially free — same inbox, same setup, just a different subject prefix — and both apps now check for them automatically on launch, so there's nothing extra to remember
- If an airport's METAR/TAF location isn't decoding in the detail view, check whether its ICAO code is in `known_airports.json` — if not, add it by hand following the existing format

---

## Appendix: Known Airports

The full list of 442 airports pre-seeded in `known_airports.json` as of this writing — 314 in the US (including DC, Guam, and Puerto Rico) and 128 international. Grouped by state, then by country, both alphabetically. This list grows over time as airports get hand-added (see [Location Decoding](#location-decoding) above) — treat this as a snapshot, not a permanent inventory. Search this page (Ctrl+F / Cmd+F) for a city or ICAO code, or jump straight to a state below.

### United States

[AK](#ak) · [AL](#al) · [AR](#ar) · [AZ](#az) · [CA](#ca) · [CO](#co) · [CT](#ct) · [DC](#dc) · [DE](#de) · [FL](#fl) · [GA](#ga) · [GU](#gu) · [HI](#hi) · [IA](#ia) · [ID](#id) · [IL](#il) · [IN](#in) · [KS](#ks) · [KY](#ky) · [LA](#la) · [MA](#ma) · [MD](#md) · [ME](#me) · [MI](#mi) · [MN](#mn) · [MO](#mo) · [MS](#ms) · [MT](#mt) · [NC](#nc) · [ND](#nd) · [NE](#ne) · [NH](#nh) · [NJ](#nj) · [NM](#nm) · [NV](#nv) · [NY](#ny) · [OH](#oh) · [OK](#ok) · [OR](#or) · [PA](#pa) · [PR](#pr) · [RI](#ri) · [SC](#sc) · [SD](#sd) · [TN](#tn) · [TX](#tx) · [UT](#ut) · [VA](#va) · [VT](#vt) · [WA](#wa) · [WI](#wi) · [WV](#wv) · [WY](#wy)


#### AK

| ICAO | Airport | City |
|------|---------|------|
| PANC | Ted Stevens Anchorage International Airport | Anchorage |
| PACV | Merle K. (Mudhole) Smith Airport | Cordova |
| PADL | Dillingham Airport | Dillingham |
| PAFA | Fairbanks International Airport | Fairbanks |
| PAGK | Gulkana Airport | Gulkana / Glennallen |
| PAJN | Juneau International Airport | Juneau |
| PAKT | Ketchikan International Airport | Ketchikan |
| PAOM | Nome Airport | Nome |
| PAPG | Petersburg James A. Johnson Airport | Petersburg |
| PASI | Sitka Rocky Gutierrez Airport | Sitka |
| PABR | Wiley Post-Will Rogers Memorial Airport | Utqiagvik / Barrow |
| PAYA | Yakutat Airport | Yakutat |

#### AL

| ICAO | Airport | City |
|------|---------|------|
| KBHM | Birmingham-Shuttlesworth International Airport | Birmingham |
| KDHN | Dothan Regional Airport | Dothan |
| KHSV | Huntsville International Airport | Huntsville |
| KMOB | Mobile Regional Airport | Mobile |

#### AR

| ICAO | Airport | City |
|------|---------|------|
| KXNA | Northwest Arkansas National Airport | Fayetteville/Bentonville |
| KHOT | Memorial Field Airport | Hot Springs |
| KLIT | Bill and Hillary Clinton National Airport | Little Rock |

#### AZ

| ICAO | Airport | City |
|------|---------|------|
| KIFP | Laughlin/Bullhead International Airport | Bullhead City |
| KFLG | Flagstaff Pulliam Airport | Flagstaff |
| KAZA | Phoenix-Mesa Gateway Airport | Mesa / Phoenix |
| KPHX | Phoenix Sky Harbor International Airport | Phoenix |
| KTUS | Tucson International Airport | Tucson |
| KYUM | Yuma International Airport | Yuma |

#### CA

| ICAO | Airport | City |
|------|---------|------|
| KBFL | Meadows Field Airport | Bakersfield |
| KBUR | Hollywood Burbank Airport | Burbank |
| KFAT | Fresno Yosemite International Airport | Fresno |
| KLAX | Los Angeles International Airport | Los Angeles |
| KACV | California Arcata-Eureka Airport | McKinleyville / Eureka |
| KMRY | Monterey Regional Airport | Monterey |
| KOAK | San Francisco Bay Oakland International Airport | Oakland |
| KONT | Ontario International Airport | Ontario |
| KPSP | Palm Springs International Airport | Palm Springs |
| KRDD | Redding Municipal Airport | Redding |
| KSMF | Sacramento International Airport | Sacramento |
| KSAN | San Diego International Airport | San Diego |
| KSFO | San Francisco International Airport | San Francisco |
| KSJC | San Jose Mineta International Airport | San Jose |
| KSBP | San Luis Obispo County Regional Airport | San Luis Obispo |
| KSNA | John Wayne Airport | Santa Ana / Orange County |
| KSBA | Santa Barbara Municipal Airport | Santa Barbara |
| KSCK | Stockton Metropolitan Airport | Stockton |

#### CO

| ICAO | Airport | City |
|------|---------|------|
| KALS | San Luis Valley Regional Airport | Alamosa |
| KASE | Aspen/Pitkin County Airport | Aspen |
| KCOS | Colorado Springs Airport | Colorado Springs |
| KDEN | Denver International Airport | Denver |
| KDRO | Durango-La Plata County Airport | Durango |
| KGJT | Grand Junction Regional Airport | Grand Junction |
| KMTJ | Montrose Regional Airport | Montrose |
| KPUB | Pueblo Memorial Airport | Pueblo |
| KHDN | Yampa Valley Regional Airport | Steamboat Springs |
| KEGE | Eagle County Regional Airport | Vail / Eagle |

#### CT

| ICAO | Airport | City |
|------|---------|------|
| KBDL | Bradley International Airport | Hartford |
| KHVN | Tweed-New Haven Airport | New Haven |

#### DC

| ICAO | Airport | City |
|------|---------|------|
| KDCA | Ronald Reagan Washington National Airport | Washington |

#### DE

| ICAO | Airport | City |
|------|---------|------|
| KILG | Wilmington Airport | Wilmington |

#### FL

| ICAO | Airport | City |
|------|---------|------|
| KVPS | Destin-Fort Walton Beach Airport | Destin / Fort Walton Beach |
| KFLL | Fort Lauderdale-Hollywood International Airport | Fort Lauderdale |
| KRSW | Southwest Florida International Airport | Fort Myers |
| KJAX | Jacksonville International Airport | Jacksonville |
| KMIA | Miami International Airport | Miami |
| KMCO | Orlando International Airport | Orlando |
| KECP | Northwest Florida Beaches International Airport | Panama City Beach |
| KPNS | Pensacola International Airport | Pensacola |
| KPGD | Punta Gorda Airport | Punta Gorda / Fort Myers |
| KSFB | Orlando Sanford International Airport | Sanford / Orlando |
| KSRQ | Sarasota-Bradenton International Airport | Sarasota |
| KPIE | St. Pete-Clearwater International Airport | St. Petersburg / Tampa |
| KTPA | Tampa International Airport | Tampa |
| KPBI | Palm Beach International Airport | West Palm Beach |

#### GA

| ICAO | Airport | City |
|------|---------|------|
| KATL | Hartsfield-Jackson Atlanta International Airport | Atlanta |
| KAGS | Augusta Regional Airport | Augusta |
| KCSG | Columbus Airport | Columbus |
| KMCN | Middle Georgia Regional Airport | Macon |
| KSAV | Savannah/Hilton Head International Airport | Savannah |

#### GU

| ICAO | Airport | City |
|------|---------|------|
| KGUM | Antonio B. Won Pat International Airport | Tamuning |

#### HI

| ICAO | Airport | City |
|------|---------|------|
| PITO | Hilo International Airport | Hilo |
| PHNL | Daniel K. Inouye International Airport | Honolulu |
| PHOG | Kahului Airport | Kahului / Maui |
| PHKO | Ellison Onizuka Kona International Airport | Kona |
| PHLI | Lihue Airport | Lihue / Kauai |

#### IA

| ICAO | Airport | City |
|------|---------|------|
| KCID | Eastern Iowa Airport | Cedar Rapids |
| KDSM | Des Moines International Airport | Des Moines |
| KSUX | Sioux Gateway Airport | Sioux City |

#### ID

| ICAO | Airport | City |
|------|---------|------|
| KBOI | Boise Airport | Boise |
| KIDA | Idaho Falls Regional Airport | Idaho Falls |
| KLWS | Lewiston-Nez Perce County Airport | Lewiston |
| KPIH | Pocatello Regional Airport | Pocatello |
| KSUN | Friedman Memorial Airport | Sun Valley / Hailey |
| KTWF | Magic Valley Regional Airport | Twin Falls |

#### IL

| ICAO | Airport | City |
|------|---------|------|
| KBLV | MidAmerica St. Louis Airport | Belleville / St. Louis |
| KBMI | Central Illinois Regional Airport | Bloomington |
| KMDW | Chicago Midway International Airport | Chicago |
| KORD | O'Hare International Airport | Chicago |
| KDEC | Decatur Airport | Decatur |
| KMLI | Quad Cities International Airport | Moline |
| KPIA | General Wayne A. Downing Peoria International Airport | Peoria |
| KSPI | Abraham Lincoln Capital Airport | Springfield |

#### IN

| ICAO | Airport | City |
|------|---------|------|
| KEVV | Evansville Regional Airport | Evansville |
| KFWA | Fort Wayne International Airport | Fort Wayne |
| KIND | Indianapolis International Airport | Indianapolis |
| KSBN | South Bend International Airport | South Bend |

#### KS

| ICAO | Airport | City |
|------|---------|------|
| KLBL | Liberal Mid-America Regional Airport | Liberal |
| KMHK | Manhattan Regional Airport | Manhattan |
| KICT | Wichita Dwight D. Eisenhower National Airport | Wichita |

#### KY

| ICAO | Airport | City |
|------|---------|------|
| KLEX | Blue Grass Airport | Lexington |
| KSDF | Louisville Muhammad Ali International Airport | Louisville |
| KOWB | Owensboro-Daviess County Regional Airport | Owensboro |
| KPAH | Barkley Regional Airport | Paducah |

#### LA

| ICAO | Airport | City |
|------|---------|------|
| KAEX | Alexandria International Airport | Alexandria |
| KBTR | Baton Rouge Metropolitan Airport | Baton Rouge |
| KLFT | Lafayette Regional Airport | Lafayette |
| KMLU | Monroe Regional Airport | Monroe |
| KMSY | Louis Armstrong New Orleans International Airport | New Orleans |
| KSHV | Shreveport Regional Airport | Shreveport |

#### MA

| ICAO | Airport | City |
|------|---------|------|
| KBOS | Logan International Airport | Boston |
| KHYA | Cape Cod Gateway Airport | Hyannis |
| KACK | Nantucket Memorial Airport | Nantucket |
| KPVC | Provincetown Municipal Airport | Provincetown |
| KMVY | Martha's Vineyard Airport | Vineyard Haven |
| KORH | Worcester Regional Airport | Worcester |

#### MD

| ICAO | Airport | City |
|------|---------|------|
| KBWI | Baltimore/Washington International Thurgood Marshall Airport | Baltimore |

#### ME

| ICAO | Airport | City |
|------|---------|------|
| KBGR | Bangor International Airport | Bangor |
| KPWM | Portland International Jetport | Portland |

#### MI

| ICAO | Airport | City |
|------|---------|------|
| KAPN | Alpena County Regional Airport | Alpena |
| KDTW | Detroit Metropolitan Wayne County Airport | Detroit |
| KESC | Delta County Airport | Escanaba |
| KFNT | Bishop International Airport | Flint |
| KGRR | Gerald R. Ford International Airport | Grand Rapids |
| KCMX | Houghton County Memorial Airport | Hancock / Houghton |
| KIMT | Ford Airport | Iron Mountain / Kingsford |
| KAZO | Kalamazoo/Battle Creek International Airport | Kalamazoo |
| KLAN | Capital Region International Airport | Lansing |
| KMQT | Sawyer International Airport | Marquette |
| KMBS | MBS International Airport | Saginaw / Midland |
| KCIU | Chippewa County International Airport | Sault Ste. Marie |
| KTVC | Cherry Capital Airport | Traverse City |

#### MN

| ICAO | Airport | City |
|------|---------|------|
| KBJI | Bemidji Regional Airport | Bemidji |
| KDLH | Duluth International Airport | Duluth |
| KHIB | Range Regional Airport | Hibbing |
| KINL | Falls International Airport | International Falls |
| KMSP | Minneapolis-Saint Paul International Airport | Minneapolis |
| KRST | Rochester International Airport | Rochester |

#### MO

| ICAO | Airport | City |
|------|---------|------|
| KBKG | Branson Airport | Branson |
| KCOU | Columbia Regional Airport | Columbia |
| KJLN | Joplin Regional Airport | Joplin |
| KSGF | Springfield-Branson National Airport | Springfield |
| KSTL | St. Louis Lambert International Airport | St. Louis |

#### MS

| ICAO | Airport | City |
|------|---------|------|
| KGPT | Gulfport-Biloxi International Airport | Gulfport |
| KJAN | Jackson-Medgar Wiley Evers International Airport | Jackson |
| KMEI | Meridian Regional Airport | Meridian |

#### MT

| ICAO | Airport | City |
|------|---------|------|
| KBIL | Billings Logan International Airport | Billings |
| KBZN | Bozeman Yellowstone International Airport | Bozeman |
| KBTM | Bert Mooney Airport | Butte |
| KGGW | Glasgow Industrial Airport | Glasgow |
| KGTF | Great Falls International Airport | Great Falls |
| KHLN | Helena Regional Airport | Helena |
| KFCA | Glacier Park International Airport | Kalispell |
| KMSO | Missoula Montana Airport | Missoula |
| KWYS | Yellowstone Airport | West Yellowstone |

#### NC

| ICAO | Airport | City |
|------|---------|------|
| KAVL | Asheville Regional Airport | Asheville |
| KCLT | Charlotte Douglas International Airport | Charlotte |
| KUSA | Concord-Padgett Regional Airport | Concord / Charlotte |
| KFAY | Fayetteville Regional Airport | Fayetteville |
| KGSO | Piedmont Triad International Airport | Greensboro |
| KOAJ | Albert J. Ellis Airport | Jacksonville |
| KRDU | Raleigh-Durham International Airport | Raleigh-Durham |
| KILM | Wilmington International Airport | Wilmington |
| KINT | Smith Reynolds Airport | Winston-Salem |

#### ND

| ICAO | Airport | City |
|------|---------|------|
| KBIS | Bismarck Municipal Airport | Bismarck |
| KDIK | Dickinson Theodore Roosevelt Regional Airport | Dickinson |
| KFAR | Hector International Airport | Fargo |
| KGFK | Grand Forks International Airport | Grand Forks |
| KMOT | Minot International Airport | Minot |

#### NE

| ICAO | Airport | City |
|------|---------|------|
| KAIA | Alliance Municipal Airport | Alliance |
| KGRI | Central Nebraska Regional Airport | Grand Island |
| KLNK | Lincoln Airport | Lincoln |
| KOMA | Eppley Airfield | Omaha |

#### NH

| ICAO | Airport | City |
|------|---------|------|
| KLEB | Lebanon Municipal Airport | Lebanon / Hanover |
| KMHT | Manchester-Boston Regional Airport | Manchester |
| KPSM | Portsmouth International Airport at Pease | Portsmouth |

#### NJ

| ICAO | Airport | City |
|------|---------|------|
| KEWR | Newark Liberty International Airport | Newark |

#### NM

| ICAO | Airport | City |
|------|---------|------|
| KALM | Alamogordo-White Sands Regional Airport | Alamogordo |
| KABQ | Albuquerque International Sunport | Albuquerque |
| KHOB | Lea County Regional Airport | Hobbs |
| KROW | Roswell Air Center | Roswell |
| KSAF | Santa Fe Regional Airport | Santa Fe |

#### NV

| ICAO | Airport | City |
|------|---------|------|
| KEKO | Elko Regional Airport | Elko |
| KLAS | Harry Reid International Airport | Las Vegas |
| KRNO | Reno/Tahoe International Airport | Reno |

#### NY

| ICAO | Airport | City |
|------|---------|------|
| KALB | Albany International Airport | Albany |
| KBGM | Greater Binghamton Airport | Binghamton |
| KBUF | Buffalo Niagara International Airport | Buffalo |
| KELM | Elmira/Corning Regional Airport | Elmira |
| KISP | Long Island MacArthur Airport | Islip |
| KITH | Ithaca Tompkins International Airport | Ithaca |
| KMSS | Massena International Airport | Massena |
| KJFK | John F. Kennedy International Airport | New York |
| KLGA | LaGuardia Airport | New York |
| KSWF | New York Stewart International Airport | Newburgh |
| KOGS | Ogdensburg International Airport | Ogdensburg |
| KPBG | Plattsburgh International Airport | Plattsburgh |
| KROC | Frederick Douglass Greater Rochester International Airport | Rochester |
| KSLK | Adirondack Regional Airport | Saranac Lake / Lake Placid |
| KSYR | Syracuse Hancock International Airport | Syracuse |
| KART | Watertown International Airport | Watertown |
| KHPN | Westchester County Airport | White Plains |

#### OH

| ICAO | Airport | City |
|------|---------|------|
| KCAK | Akron-Canton Airport | Akron / Canton |
| KCVG | Cincinnati/Northern Kentucky International Airport | Cincinnati |
| KCLE | Cleveland Hopkins International Airport | Cleveland |
| KCMH | John Glenn Columbus International Airport | Columbus |
| KLCK | Rickenbacker International Airport | Columbus |
| KDAY | James M. Cox Dayton International Airport | Dayton |
| KTOL | Eugene F. Kranz Toledo Express Airport | Toledo |

#### OK

| ICAO | Airport | City |
|------|---------|------|
| KLAW | Lawton-Fort Sill Regional Airport | Lawton |
| KOKC | Will Rogers World Airport | Oklahoma City |
| KTUL | Tulsa International Airport | Tulsa |

#### OR

| ICAO | Airport | City |
|------|---------|------|
| KEUG | Eugene Airport | Eugene |
| KMFR | Rogue Valley International-Medford Airport | Medford |
| KOTH | Southwest Oregon Regional Airport | North Bend / Coos Bay |
| KPDX | Portland International Airport | Portland |
| KRDM | Redmond Municipal Airport | Redmond / Bend |

#### PA

| ICAO | Airport | City |
|------|---------|------|
| KABE | Lehigh Valley International Airport | Allentown |
| KAVP | Wilkes-Barre/Scranton International Airport | Avoca / Scranton |
| KERI | Erie International Airport | Erie |
| KMDT | Harrisburg International Airport | Harrisburg |
| KLNS | Lancaster Airport | Lancaster |
| KPIT | Pittsburgh International Airport | Pittsburgh |

#### PR

| ICAO | Airport | City |
|------|---------|------|
| TJBQ | Rafael Hernández International Airport | Aguadilla |
| TJCP | Benjamin Rivera Noriega Airport | Culebra |
| TJPS | Mercedita Airport | Ponce |
| TJSJ | Luis Muñoz Marín International Airport | San Juan |
| TJVQ | Antonio Rivera Rodríguez Airport | Vieques |

#### RI

| ICAO | Airport | City |
|------|---------|------|
| KPVD | Rhode Island T.F. Green International Airport | Providence |

#### SC

| ICAO | Airport | City |
|------|---------|------|
| KCHS | Charleston International Airport | Charleston |
| KCAE | Columbia Metropolitan Airport | Columbia |
| KGSP | Greenville-Spartanburg International Airport | Greenville-Spartanburg |
| KHHH | Hilton Head Airport | Hilton Head Island |
| KMYR | Myrtle Beach International Airport | Myrtle Beach |
| KUZA | Rock Hill/York County Airport (Bryant Field) | Rock Hill |

#### SD

| ICAO | Airport | City |
|------|---------|------|
| KHON | Huron Regional Airport | Huron |
| KPIR | Pierre Regional Airport | Pierre |
| KRAP | Rapid City Regional Airport | Rapid City |
| KFSD | Sioux Falls Regional Airport | Sioux Falls |

#### TN

| ICAO | Airport | City |
|------|---------|------|
| KTRI | Tri-Cities Airport | Blountville / Johnson City |
| KCHA | Chattanooga Metropolitan Airport | Chattanooga |
| KTYS | McGhee Tyson Airport | Knoxville |
| KMEM | Memphis International Airport | Memphis |
| KBNA | Nashville International Airport | Nashville |

#### TX

| ICAO | Airport | City |
|------|---------|------|
| KABI | Abilene Regional Airport | Abilene |
| KAMA | Rick Husband Amarillo International Airport | Amarillo |
| KAUS | Austin-Bergstrom International Airport | Austin |
| KBPT | Jack Brooks Regional Airport | Beaumont / Port Arthur |
| KBRO | Brownsville/South Padre Island International Airport | Brownsville |
| KCLL | Easterwood Airport | College Station |
| KCRP | Corpus Christi International Airport | Corpus Christi |
| KDFW | Dallas/Fort Worth International Airport | Dallas-Fort Worth |
| KELP | El Paso International Airport | El Paso |
| KHRL | Valley International Airport | Harlingen |
| KHOU | William P. Hobby Airport | Houston |
| KIAH | George Bush Intercontinental Airport | Houston |
| KLRD | Laredo International Airport | Laredo |
| KGGG | East Texas Regional Airport | Longview |
| KLBB | Lubbock Preston Smith International Airport | Lubbock |
| KMFE | McAllen Miller International Airport | McAllen |
| KMAF | Midland International Air and Space Port | Midland / Odessa |
| KSJT | San Angelo Regional Airport | San Angelo |
| KSAT | San Antonio International Airport | San Antonio |
| KTYR | Tyler Pounds Regional Airport | Tyler |
| KACT | Waco Regional Airport | Waco |

#### UT

| ICAO | Airport | City |
|------|---------|------|
| KCDC | Cedar City Regional Airport | Cedar City |
| KCNY | Canyonlands Regional Airport | Moab |
| KOGD | Ogden-Hinckley Airport | Ogden |
| KPVU | Provo Municipal Airport | Provo / Salt Lake City |
| KSLC | Salt Lake City International Airport | Salt Lake City |
| KSGU | St. George Regional Airport | St. George |
| KVEL | Vernal Regional Airport | Vernal |
| KENV | Wendover Airport | Wendover |

#### VA

| ICAO | Airport | City |
|------|---------|------|
| KCHO | Charlottesville-Albemarle Airport | Charlottesville |
| KPHF | Newport News/Williamsburg International Airport | Newport News |
| KORF | Norfolk International Airport | Norfolk |
| KRIC | Richmond International Airport | Richmond |
| KROA | Roanoke-Blacksburg Regional Airport | Roanoke |
| KSHD | Shenandoah Valley Regional Airport | Staunton / Harrisonburg |
| KIAD | Washington Dulles International Airport | Washington |

#### VT

| ICAO | Airport | City |
|------|---------|------|
| KBTV | Patrick Leahy Burlington International Airport | Burlington |

#### WA

| ICAO | Airport | City |
|------|---------|------|
| KBLI | Bellingham International Airport | Bellingham |
| KPSC | Tri-Cities Airport | Pasco / Tri-Cities |
| KBFI | King County International Airport | Seattle |
| KSEA | Seattle-Tacoma International Airport | Seattle |
| KGEG | Spokane International Airport | Spokane |
| KEAT | Pangborn Memorial Airport | Wenatchee |
| KYKM | Yakima Air Terminal | Yakima |

#### WI

| ICAO | Airport | City |
|------|---------|------|
| KATW | Appleton International Airport | Appleton |
| KEAU | Chippewa Valley Regional Airport | Eau Claire |
| KGRB | Green Bay Austin Straubel International Airport | Green Bay |
| KLSE | La Crosse Regional Airport | La Crosse |
| KMSN | Dane County Regional Airport | Madison |
| KMKE | Milwaukee Mitchell International Airport | Milwaukee |
| KCWA | Central Wisconsin Airport | Mosinee / Wausau |
| KRHI | Rhinelander-Oneida County Airport | Rhinelander |

#### WV

| ICAO | Airport | City |
|------|---------|------|
| KBKW | Raleigh County Memorial Airport | Beckley |
| KCRW | West Virginia International Yeager Airport | Charleston |
| KCKB | North Central West Virginia Airport | Clarksburg |
| KHTS | Tri-State Airport | Huntington |
| KLWB | Greenbrier Valley Airport | Lewisburg |

#### WY

| ICAO | Airport | City |
|------|---------|------|
| KCPR | Casper-Natrona County International Airport | Casper |
| KCYS | Cheyenne Regional Airport | Cheyenne |
| KCOD | Yellowstone Regional Airport | Cody |
| KGCC | Gillette-Campbell County Airport | Gillette |
| KJAC | Jackson Hole Airport | Jackson Hole |
| KLAR | Laramie Regional Airport | Laramie |
| KRKS | Southwest Wyoming Regional Airport | Rock Springs |

### International


**Anguilla**

| ICAO | Airport | City |
|------|---------|------|
| TQPF | Clayton J. Lloyd International Airport | The Valley |

**Antigua and Barbuda**

| ICAO | Airport | City |
|------|---------|------|
| TAPA | V. C. Bird International Airport | St. John's |

**Argentina**

| ICAO | Airport | City |
|------|---------|------|
| SAEZ | Ministro Pistarini International Airport | Buenos Aires |

**Aruba**

| ICAO | Airport | City |
|------|---------|------|
| TNCA | Queen Beatrix International Airport | Oranjestad |

**Australia**

| ICAO | Airport | City |
|------|---------|------|
| YBBN | Brisbane Airport | Brisbane |
| YMML | Melbourne Airport | Melbourne |
| YSSY | Sydney Kingsford Smith Airport | Sydney |

**Austria**

| ICAO | Airport | City |
|------|---------|------|
| LOWW | Vienna International Airport | Vienna |

**BVI**

| ICAO | Airport | City |
|------|---------|------|
| TUPJ | Terrance B. Lettsome International Airport | Beef Island / Tortola |
| TUPW | Virgin Gorda Airport | Virgin Gorda |

**Bahamas**

| ICAO | Airport | City |
|------|---------|------|
| MYAC | Arthur's Town Airport | Arthur's Town |
| MYEC | Cape Eleuthera Airport | Cape Eleuthera |
| MYGF | Grand Bahama International Airport | Freeport |
| MYEM | Governor's Harbour Airport | Governor's Harbour |
| MYAM | Marsh Harbour Airport | Marsh Harbour / Abaco |
| MYNN | Lynden Pindling International Airport | Nassau |
| MYEH | North Eleuthera Airport | North Eleuthera |
| MYER | Rock Sound International Airport | Rock Sound |
| MYAT | Treasure Cay Airport | Treasure Cay / Abaco |

**Barbados**

| ICAO | Airport | City |
|------|---------|------|
| TBPB | Grantley Adams International Airport | Bridgetown |

**Belgium**

| ICAO | Airport | City |
|------|---------|------|
| EBBR | Brussels Airport | Brussels |

**Bermuda**

| ICAO | Airport | City |
|------|---------|------|
| TXKF | L.F. Wade International Airport | Hamilton |

**Bonaire**

| ICAO | Airport | City |
|------|---------|------|
| TNCB | Flamingo International Airport | Kralendijk |

**Brazil**

| ICAO | Airport | City |
|------|---------|------|
| SBBR | Brasília International Airport | Brasília |
| SBGL | Rio de Janeiro/Galeão International Airport | Rio de Janeiro |
| SBGR | São Paulo/Guarulhos International Airport | São Paulo |

**Canada**

| ICAO | Airport | City |
|------|---------|------|
| CYYC | Calgary International Airport | Calgary, AB |
| CYUL | Montréal-Trudeau International Airport | Montreal, QC |
| CYYZ | Toronto Pearson International Airport | Toronto, ON |
| CYVR | Vancouver International Airport | Vancouver, BC |

**Caribbean Netherlands**

| ICAO | Airport | City |
|------|---------|------|
| TNCS | Juancho E. Yrausquin Airport | Saba |

**Cayman Islands**

| ICAO | Airport | City |
|------|---------|------|
| MWCR | Owen Roberts International Airport | George Town |

**Chile**

| ICAO | Airport | City |
|------|---------|------|
| SCEL | Arturo Merino Benítez International Airport | Santiago |

**China**

| ICAO | Airport | City |
|------|---------|------|
| ZBAA | Beijing Capital International Airport | Beijing |
| ZSPD | Shanghai Pudong International Airport | Shanghai |

**Colombia**

| ICAO | Airport | City |
|------|---------|------|
| SKBO | El Dorado International Airport | Bogota |
| SKRG | José María Córdova International Airport | Medellín |

**Costa Rica**

| ICAO | Airport | City |
|------|---------|------|
| MRLB | Daniel Oduber Quirós International Airport | Liberia |
| MROC | Juan Santamaría International Airport | San José |

**Cuba**

| ICAO | Airport | City |
|------|---------|------|
| MUHA | José Martí International Airport | Havana |

**Curaçao**

| ICAO | Airport | City |
|------|---------|------|
| TNCC | Curaçao International Airport | Willemstad |

**Czech Republic**

| ICAO | Airport | City |
|------|---------|------|
| LKPR | Václav Havel Airport Prague | Prague |

**Denmark**

| ICAO | Airport | City |
|------|---------|------|
| EKCH | Copenhagen Airport | Copenhagen |

**Dominica**

| ICAO | Airport | City |
|------|---------|------|
| TDPD | Douglas-Charles Airport | Marigot |

**Dominican Republic**

| ICAO | Airport | City |
|------|---------|------|
| MDLR | La Romana International Airport | La Romana |
| MDPP | Gregorio Luperón International Airport | Puerto Plata |
| MDPC | Punta Cana International Airport | Punta Cana |
| MDST | Cibao International Airport | Santiago de los Caballeros |
| MDSD | Las Américas International Airport | Santo Domingo |

**Ecuador**

| ICAO | Airport | City |
|------|---------|------|
| SEGU | José Joaquín de Olmedo International Airport | Guayaquil |
| SEQM | Mariscal Sucre International Airport | Quito |

**El Salvador**

| ICAO | Airport | City |
|------|---------|------|
| MSLP | Monseñor Óscar Arnulfo Romero International Airport | San Salvador |

**Finland**

| ICAO | Airport | City |
|------|---------|------|
| EFHK | Helsinki-Vantaa Airport | Helsinki |

**France**

| ICAO | Airport | City |
|------|---------|------|
| LFMN | Nice Côte d'Azur Airport | Nice |
| LFPG | Charles de Gaulle Airport | Paris |

**French Polynesia**

| ICAO | Airport | City |
|------|---------|------|
| NTAA | Fa'a'ā International Airport | Papeete |

**Germany**

| ICAO | Airport | City |
|------|---------|------|
| EDDB | Berlin Brandenburg Airport | Berlin |
| EDDF | Frankfurt Airport | Frankfurt |
| EDDM | Munich Airport | Munich |

**Ghana**

| ICAO | Airport | City |
|------|---------|------|
| DGAA | Kotoka International Airport | Accra |

**Greece**

| ICAO | Airport | City |
|------|---------|------|
| LGAV | Athens International Airport | Athens |

**Greenland**

| ICAO | Airport | City |
|------|---------|------|
| BGBW | Narsarsuaq Airport | Narsarsuaq |

**Grenada**

| ICAO | Airport | City |
|------|---------|------|
| TGPY | Maurice Bishop International Airport | St. George's |

**Guadeloupe**

| ICAO | Airport | City |
|------|---------|------|
| TFFR | Pointe-à-Pitre International Airport | Pointe-à-Pitre |

**Guatemala**

| ICAO | Airport | City |
|------|---------|------|
| MGGT | La Aurora International Airport | Guatemala City |

**Guyana**

| ICAO | Airport | City |
|------|---------|------|
| SYCJ | Cheddi Jagan International Airport | Georgetown |

**Haiti**

| ICAO | Airport | City |
|------|---------|------|
| MTCH | Cap-Haïtien International Airport | Cap-Haïtien |
| MTPP | Toussaint Louverture International Airport | Port-au-Prince |

**Honduras**

| ICAO | Airport | City |
|------|---------|------|
| MHTG | Toncontín / Palmerola International Airport | Tegucigalpa / Comayagua |

**Hong Kong**

| ICAO | Airport | City |
|------|---------|------|
| VHHH | Hong Kong International Airport | Hong Kong |

**Hungary**

| ICAO | Airport | City |
|------|---------|------|
| LHBP | Budapest Ferenc Liszt International Airport | Budapest |

**Iceland**

| ICAO | Airport | City |
|------|---------|------|
| BIKF | Keflavík International Airport | Reykjavík |

**India**

| ICAO | Airport | City |
|------|---------|------|
| VABB | Chhatrapati Shivaji Maharaj International Airport | Mumbai |
| VIDP | Indira Gandhi International Airport | New Delhi |

**Ireland**

| ICAO | Airport | City |
|------|---------|------|
| EIDW | Dublin Airport | Dublin |

**Israel**

| ICAO | Airport | City |
|------|---------|------|
| LLBG | Ben Gurion Airport | Tel Aviv |

**Italy**

| ICAO | Airport | City |
|------|---------|------|
| LIMC | Milan Malpensa Airport | Milan |
| LIRF | Leonardo da Vinci–Fiumicino Airport | Rome |
| LIPZ | Venice Marco Polo Airport | Venice |

**Jamaica**

| ICAO | Airport | City |
|------|---------|------|
| MKJP | Norman Manley International Airport | Kingston |
| MKJS | Sangster International Airport | Montego Bay |
| MKOC | Ian Fleming International Airport | Ocho Rios |

**Japan**

| ICAO | Airport | City |
|------|---------|------|
| RJAA | Narita International Airport | Tokyo |
| RJTT | Tokyo Haneda Airport | Tokyo |

**Jordan**

| ICAO | Airport | City |
|------|---------|------|
| OJAI | Queen Alia International Airport | Amman |

**Mexico**

| ICAO | Airport | City |
|------|---------|------|
| MMUN | Cancún International Airport | Cancún |
| MMMX | Mexico City International Airport | Mexico City |
| MMPR | Puerto Vallarta International Airport | Puerto Vallarta |
| MMSD | Los Cabos International Airport | San José del Cabo |

**Morocco**

| ICAO | Airport | City |
|------|---------|------|
| GMMX | Marrakesh Menara Airport | Marrakesh |

**Netherlands**

| ICAO | Airport | City |
|------|---------|------|
| EHAM | Amsterdam Airport Schiphol | Amsterdam |

**New Zealand**

| ICAO | Airport | City |
|------|---------|------|
| NZAA | Auckland Airport | Auckland |

**Nicaragua**

| ICAO | Airport | City |
|------|---------|------|
| MNMG | Augusto C. Sandino International Airport | Managua |

**Nigeria**

| ICAO | Airport | City |
|------|---------|------|
| DNMM | Murtala Muhammed International Airport | Lagos |

**Norway**

| ICAO | Airport | City |
|------|---------|------|
| ENGM | Oslo Airport, Gardermoen | Oslo |

**Panama**

| ICAO | Airport | City |
|------|---------|------|
| MPTO | Tocumen International Airport | Panama City |

**Peru**

| ICAO | Airport | City |
|------|---------|------|
| SPJC | Jorge Chávez International Airport | Lima |

**Philippines**

| ICAO | Airport | City |
|------|---------|------|
| RPLL | Ninoy Aquino International Airport | Manila |

**Poland**

| ICAO | Airport | City |
|------|---------|------|
| EPWA | Warsaw Chopin Airport | Warsaw |

**Portugal**

| ICAO | Airport | City |
|------|---------|------|
| LPPT | Humberto Delgado Airport | Lisbon |
| LPPR | Francisco Sá Carneiro Airport | Porto |

**Qatar**

| ICAO | Airport | City |
|------|---------|------|
| OTHH | Hamad International Airport | Doha |

**Saint Lucia**

| ICAO | Airport | City |
|------|---------|------|
| TLPL | Hewanorra International Airport | Vieux Fort |

**Saudi Arabia**

| ICAO | Airport | City |
|------|---------|------|
| OEMA | Prince Mohammad bin Abdulaziz International Airport | Medina |

**Singapore**

| ICAO | Airport | City |
|------|---------|------|
| WSSS | Singapore Changi Airport | Singapore |

**Sint Maarten**

| ICAO | Airport | City |
|------|---------|------|
| TNCM | Princess Juliana International Airport | Philipsburg |

**South Africa**

| ICAO | Airport | City |
|------|---------|------|
| FACT | Cape Town International Airport | Cape Town |
| FAOR | O. R. Tambo International Airport | Johannesburg |

**South Korea**

| ICAO | Airport | City |
|------|---------|------|
| RKSI | Incheon International Airport | Seoul |

**Spain**

| ICAO | Airport | City |
|------|---------|------|
| LEBL | Josep Tarradellas Barcelona-El Prat Airport | Barcelona |
| LEMD | Adolfo Suárez Madrid–Barajas Airport | Madrid |

**St. Barthélemy**

| ICAO | Airport | City |
|------|---------|------|
| TFFJ | Gustaf III Airport | St. Jean |

**St. Vincent & Grenadines**

| ICAO | Airport | City |
|------|---------|------|
| TVSA | Argyle International Airport | Kingstown |

**Switzerland**

| ICAO | Airport | City |
|------|---------|------|
| LSGG | Geneva Airport | Geneva |
| LSZH | Zurich Airport | Zurich |

**Taiwan**

| ICAO | Airport | City |
|------|---------|------|
| RCTP | Taiwan Taoyuan International Airport | Taipei |

**Thailand**

| ICAO | Airport | City |
|------|---------|------|
| VTBS | Suvarnabhumi Airport | Bangkok |

**Tobago**

| ICAO | Airport | City |
|------|---------|------|
| TTCP | A.N.R. Robinson International Airport | Crown Point |

**Trinidad and Tobago**

| ICAO | Airport | City |
|------|---------|------|
| TTPP | Piarco International Airport | Port of Spain |

**Turkey**

| ICAO | Airport | City |
|------|---------|------|
| LTFM | Istanbul Airport | Istanbul |

**Turks and Caicos**

| ICAO | Airport | City |
|------|---------|------|
| MBGT | JAGS McCartney International Airport | Cockburn Town |
| MBPV | Providenciales International Airport | Providenciales |

**USVI**

| ICAO | Airport | City |
|------|---------|------|
| TISX | Henry E. Rohlsen Airport | St. Croix |
| TIST | Cyril E. King Airport | St. Thomas |

**United Arab Emirates**

| ICAO | Airport | City |
|------|---------|------|
| OMDB | Dubai International Airport | Dubai |

**United Kingdom**

| ICAO | Airport | City |
|------|---------|------|
| EGPH | Edinburgh Airport | Edinburgh |
| EGLL | London Heathrow Airport | London |

**Uruguay**

| ICAO | Airport | City |
|------|---------|------|
| SUMU | Carrasco International Airport | Montevideo |
