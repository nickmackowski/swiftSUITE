import Foundation

// MARK: - App Storage Location

/// Resolves the directory the compiled binary itself lives in — not the current working
/// directory, which varies by how the app is launched. Kept consistent with the rest of the
/// suite so calendar.json, the debug log, and the sync helper script are all found reliably
/// regardless of how/where swiftCALENDAR is launched from.
func resolveAppDataDirectory() -> URL {
    let executablePath = CommandLine.arguments.first ?? "."
    return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
}

// MARK: - Debug Logger

class CalendarDebugLogger {
    static let logURL: URL = resolveAppDataDirectory().appendingPathComponent("swiftcalendar_debug.log")
    
    static func log(_ message: String, category: String = "GENERAL") {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(category)] \(message)\n"
        
        guard let data = logLine.data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Models

struct CalendarEvent: Codable {
    var id: UUID = UUID()
    var title: String = ""
    var location: String = ""
    var startTime: Date = Date()
    var endTime: Date = Date()
    var notes: String = ""
    var calendarName: String = ""
    var isAllDay: Bool = false
    var isLocal: Bool = false      // true = created in-app, kept across syncs
    var isWeather: Bool = false    // true = METAR history entry — set at load time only, never read
                                    // from or written to disk (see CodingKeys below)
    var decodedWeather: String? = nil  // plain-English METAR/TAF decode for the detail view only —
                                        // agenda/title keeps the raw code. nil for non-weather events.
                                        // Optional, so a missing key in older calendar.json entries or
                                        // regular ICS events decodes safely as nil (no CodingKeys
                                        // exclusion needed, unlike isWeather — see note below).

    // isWeather is intentionally omitted here. Swift's synthesized Decodable requires a JSON
    // key for every listed property regardless of its default value, so including isWeather
    // would break decoding of calendar.json and metar_history.json entirely (neither file
    // contains that key). Leaving it out of CodingKeys means it's skipped during decode/encode
    // and simply keeps its default (false) until loadWeatherHistory() sets it explicitly.
    //
    // decodedWeather is the opposite case: it DOES need to round-trip to/from JSON (calendar_sync.py
    // writes it for METAR/TAF events), so it MUST be listed here — if a future edit adds a new
    // Optional property and forgets to add it to this enum, it'll silently decode as nil forever
    // regardless of what's actually in the file, which is easy to miss since nothing throws.
    enum CodingKeys: String, CodingKey {
        case id, title, location, startTime, endTime, notes, calendarName, isAllDay, isLocal, decodedWeather
    }
}

struct CalendarAccount: Codable {
    var id: String = UUID().uuidString
    var name: String = ""       // used as calendarName for all events from this feed
    var url: String = ""        // ICS URL for ics type; airport code (e.g. KCLT) for metar type
    var enabled: Bool = true
    var colorIndex: Int = -1    // -1 = none, 0–7 = palette index
    var type: String = "ics"   // "ics", "metar", or "taf"
    var lat: String = ""         // optional lat for NWS temp fetch (TAF only)
    var lon: String = ""         // optional lon for NWS temp fetch (TAF only)
}

// Color palette — 8 choices for assigning to calendars
let calendarColorPalette: [(name: String, ansi: String)] = [
    ("Cyan",    "\u{001B}[1;36m"),
    ("Green",   "\u{001B}[1;32m"),
    ("Yellow",  "\u{001B}[1;33m"),
    ("Magenta", "\u{001B}[1;35m"),
    ("Orange",  "\u{001B}[38;5;208m"),
    ("Blue",    "\u{001B}[1;34m"),
    ("Purple",  "\u{001B}[38;5;135m"),
    // Red (\u{001B}[1;31m) is reserved for Local events — not available in picker
]

// MARK: - Emoji-Aware Display Width
// Swift's String.count treats emoji as 1 character but terminals render them as 2 columns.
// This extension gives the correct visual width for padding calculations.
extension String {
    var displayWidth: Int {
        var width = 0
        for scalar in unicodeScalars {
            let v = scalar.value
            if v == 0xFE0F || v == 0x200D || (v >= 0x200B && v <= 0x200F) {
                continue  // zero-width: variation selector, ZWJ, etc.
            } else if v >= 0x1F000 ||                        // supplement plane emoji
                      (v >= 0x2600 && v <= 0x27BF) ||       // misc symbols (☁️☀️⛅ etc)
                      (v >= 0x2B00 && v <= 0x2BFF) ||       // misc symbols extended
                      (v >= 0xFF01 && v <= 0xFF60) {         // full-width latin
                width += 2
            } else {
                width += 1
            }
        }
        return width
    }
}

// MARK: - Navigation State

enum CalScreen {
    case monthView
    case viewEvent(event: CalendarEvent)
    case addEvent
    case colorSetup
}

// MARK: - Interactive Keyboard Engine (POSIX Raw Mode)

enum CalKey {
    case up, down, left, right, enter, escape
    case char(Character)
}

class CalKeyboardReader {
    private var originalTermios = termios()

    func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        raw = originalTermios
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
        raw.c_cc.16 = 1 
        raw.c_cc.17 = 0 
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    func disableRawMode() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }

    func readKey() -> CalKey {
        var buffer = [UInt8](repeating: 0, count: 3)
        let bytesRead = read(STDIN_FILENO, &buffer, 3)
        if bytesRead <= 0 { return .char("\0") }
        
        if buffer[0] == 27 { 
            if bytesRead == 1 { return .escape }
            if buffer[1] == 91 { 
                switch buffer[2] {
                case 65: return .up    
                case 66: return .down  
                case 67: return .right 
                case 68: return .left  
                default: return .escape
                }
            }
            return .escape
        }
        if buffer[0] == 10 { return .enter }
        return .char(Character(UnicodeScalar(buffer[0])))
    }
}

// MARK: - Application Core Logic

class CalendarManager {
    var events: [CalendarEvent] = []
    var calendarAccounts: [CalendarAccount] = []
    let localEventsURL    = resolveAppDataDirectory().appendingPathComponent("local_events.json")
    let weatherHistoryURL = resolveAppDataDirectory().appendingPathComponent("metar_history.json")
    let configURL      = resolveAppDataDirectory().appendingPathComponent("calendar_accounts.json")
    var currentScreen: CalScreen = .monthView
    var running = true
    
    var selectedDate = Date()
    let keyboard = CalKeyboardReader()
    let fileURL = resolveAppDataDirectory().appendingPathComponent("calendar.json")

    func colorForCalendar(_ name: String) -> String {
        guard let acct = calendarAccounts.first(where: { $0.name == name }),
              acct.colorIndex >= 0 && acct.colorIndex < calendarColorPalette.count else { return "" }
        return calendarColorPalette[acct.colorIndex].ansi
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let accts = try? JSONDecoder().decode([CalendarAccount].self, from: data) else { return }
        calendarAccounts = accts
    }

    func saveConfig() {
        guard let data = try? JSONEncoder().encode(calendarAccounts) else { return }
        try? data.write(to: configURL)
    }
    
    var lastSyncStatus: String? = nil
    var lastSyncWasError = false
    
    // Extracted live telemetry variables
    var machineName: String = "macOS"
    var uptime: String = "Unknown"
    var cpuUsage: String = "0%"
    var memUsage: String = "0G"
    
    init() {
        loadConfig()
        loadEvents()
        loadLocalEvents()
        loadWeatherHistory()
        parseLauncherArguments()
    }
    
    // Extracts telemetry args securely pushed from the launcher matrix
    private func parseLauncherArguments() {
        let args = CommandLine.arguments
        if args.count >= 5 {
            self.machineName = args[1]
            self.uptime = args[2]
            self.cpuUsage = args[3]
            self.memUsage = args[4]
        }
    }
    
    func run() {
        while running {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            switch currentScreen {
            case .monthView:
                showMonthView()
            case .viewEvent(let event):
                showViewEventScreen(event: event)
            case .addEvent:
                showAddEventScreen()
                currentScreen = .monthView
            case .colorSetup:
                showAccountSetupScreen()
                currentScreen = .monthView
            }
        }
    }
    
    // MARK: - Unified 80-Column Layout Handlers
    
    private func printStandardHeader() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yy"
        let dateString = dateFormatter.string(from: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "hh:mm:ss a"
        let timeString = timeFormatter.string(from: now).uppercased()

        let innerWidth = 118
        let titleText = "swiftCALENDAR v2.7.07.18c"  // plain for layout; c colored below
        let sidePadding = (innerWidth - titleText.count) / 2
        var titleLineChars = Array(repeating: " ", count: innerWidth)
        for (i, ch) in dateString.enumerated() where i < innerWidth { titleLineChars[i] = String(ch) }
        for (i, ch) in titleText.enumerated() { titleLineChars[sidePadding + i] = String(ch) }
        // Color the trailing 'c' orange without affecting layout positions
        titleLineChars[sidePadding + titleText.count - 1] = "\u{001B}[38;5;208mc\u{001B}[0m"
        let timeStart = innerWidth - timeString.count
        for (i, ch) in timeString.enumerated() { titleLineChars[timeStart + i] = String(ch) }

        let sessionFile = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftcore")
            .appendingPathComponent(".core_session")
        var sessionUser = "UNKNOWN"
        if let sc = try? String(contentsOf: sessionFile, encoding: .utf8) {
            for line in sc.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: ":")
                if parts.count == 2 && parts[0] == "user" { sessionUser = parts[1]; break }
            }
        }

        let seg1Raw = "User: \(sessionUser)"
        let seg1Col = "User: \u{001B}[1;33m\(sessionUser)\u{001B}[0m"
        let seg2 = "Connected: [\(machineName)]"
        let seg3 = "Host Uptime: \(uptime)"
        let seg4 = "CPU: \(cpuUsage)"
        let seg5 = "Mem: \(memUsage)"
        let remaining = max(4, innerWidth - seg1Raw.count - seg2.count - seg3.count - seg4.count - seg5.count)
        let base = String(repeating: " ", count: remaining / 4)
        let extra = remaining % 4
        let telRaw = "\(seg1Raw)\(base+(extra>0 ? " " : ""))\(seg2)\(base+(extra>1 ? " " : ""))\(seg3)\(base+(extra>2 ? " " : ""))\(seg4)\(base)\(seg5)"
        let telCol = "\(seg1Col)\(base+(extra>0 ? " " : ""))\(seg2)\(base+(extra>1 ? " " : ""))\(seg3)\(base+(extra>2 ? " " : ""))\(seg4)\(base)\(seg5)"
        let telPad = max(0, innerWidth - telRaw.count)

        print("╭" + String(repeating: "─", count: innerWidth) + "╮")
        print("│" + titleLineChars.joined() + "│")
        print("│" + telCol + String(repeating: " ", count: telPad) + "│")
        print("╰" + String(repeating: "─", count: innerWidth) + "╯")
    }
    
    private func printStandardFooter(keys: String = "←/→: Day  ↑/↓: Week  <,: Prev Month  .:> Next Month  [E] New Event  [A] Accounts  ENTER: View") {
        let inner = 118
        let p = max(0, (inner - keys.count) / 2)
        print("╭" + String(repeating: "─", count: inner) + "╮")
        print("│" + String(repeating: " ", count: p) + keys + String(repeating: " ", count: inner - p - keys.count) + "│")
        print("╰" + String(repeating: "─", count: inner) + "╯")
    }
    
    // MARK: - Layout Render Panels
    
    func showMonthView() {
        keyboard.enableRawMode()
        rebuildEventsByDayCache()
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: selectedDate)
        guard let startOfMonth = calendar.date(from: components),
              let rangeOfDays = calendar.range(of: .day, in: .month, for: selectedDate) else {
            keyboard.disableRawMode()
            return
        }
        
        let startWeekday = calendar.component(.weekday, from: startOfMonth) 
        let totalDays = rangeOfDays.count
        
        printStandardHeader()
        
        let eventLabel = "\(events.count) Event\(events.count == 1 ? "" : "s") Loaded"
        let calLeftText = " CALENDAR: \(eventLabel)"
        
        // Staleness is derived from calendar.json's actual file-modification time rather than
        // an in-memory flag, so it survives app restarts and reflects reality even if the app
        // was quit and relaunched without a fresh sync — the file's mtime is set precisely
        // whenever a sync last wrote it (by either this app or the Python helper).
        let syncModDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        let syncFormatter = DateFormatter()
        syncFormatter.dateFormat = "MM-dd-yy hh:mm a"
        
        let calRightText: String
        let isStale: Bool
        if let syncDate = syncModDate {
            calRightText = "● Last Sync: \(syncFormatter.string(from: syncDate).uppercased())"
            isStale = Date().timeIntervalSince(syncDate) > 24 * 3600 // 24hr staleness, same idea as the stock app's market-open/closed indicator
        } else {
            calRightText = "● Last Sync: Never"
            isStale = true
        }
        let calRightColor = isStale ? "\u{001B}[1;31m" : "\u{001B}[1;32m"
        
        let calPadding = max(1, 119 - calLeftText.count - calRightText.count)
        print("\u{001B}[1;37m CALENDAR:\u{001B}[0m \(eventLabel)\(String(repeating: " ", count: calPadding))\(calRightColor)\(calRightText)\u{001B}[0m")
        let calendarNames = Set(events.map { $0.calendarName }.filter { !$0.isEmpty })
        let calCount = max(1, calendarNames.count)
        let secondLine = " \(events.count) Event\(events.count == 1 ? "" : "s") from \(calCount) Calendar\(calCount == 1 ? "" : "s")  [R] to sync"
        print(secondLine)

        // ── Month grid box ──────────────────────────────────────────────────
        // 6-char indent + 7 columns * 16 chars = 118 inner width exactly
        let colW      = 16
        let calIndent = 6
        let inner     = 118
        let greenBG   = "\u{001B}[48;5;22m"
        let yellowHL  = "\u{001B}[1;33m"
        let calReset  = "\u{001B}[0m"

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        let monthHeader = monthFormatter.string(from: selectedDate).uppercased()
        let mPad = max(0, inner - monthHeader.count)

        let dayLabelRow = String(repeating: " ", count: calIndent) +
            ["SUN","MON","TUE","WED","THU","FRI","SAT"]
                .map { $0.padding(toLength: colW, withPad: " ", startingAt: 0) }.joined()

        let selectedDay = calendar.component(.day, from: selectedDate)

        // Determine if we're viewing the current month to show today's highlight
        let nowComps      = calendar.dateComponents([.year, .month, .day], from: Date())
        let selComps      = calendar.dateComponents([.year, .month], from: selectedDate)
        let isCurrentMonth = nowComps.year == selComps.year && nowComps.month == selComps.month
        let todayDay      = isCurrentMonth ? nowComps.day : nil

        // Build a 16-char cell — color communicates everything, no * needed
        // Has events → bright white   No events → dim   Today → green bg + bright white   Cursor → yellow
        let dimText    = "\u{001B}[2m"
        let brightText = "\u{001B}[1;97m"
        let localRed    = "\u{001B}[1;31m"  // shared with the agenda list below so grid/agenda always match
        let weatherBlue = "\u{001B}[1;34m"  // same — shared between grid and agenda, METAR history entries

        func calCell(day: Int, eventColor: String) -> String {
            let dayStr  = String(format: "%02d", day)
            let spacer  = String(repeating: " ", count: colW - 2)
            let isSel   = day == selectedDay
            let isToday = day == todayDay
            let hasEvt  = !eventColor.isEmpty

            if isSel && isToday  { return "\(greenBG)\(yellowHL)\(dayStr)\(calReset)\(spacer)" }
            if isToday           { return "\(greenBG)\(brightText)\(dayStr)\(calReset)\(spacer)" }
            if isSel             { return "\(yellowHL)\(dayStr)\(calReset)\(spacer)" }
            if hasEvt            { return "\(eventColor)\(dayStr)\(calReset)\(spacer)" }
            return "\(dimText)\(dayStr)\(calReset)\(spacer)"
        }

        // Returns the color of the first calendar with events on this day
        func eventColorForDay(_ day: Int) -> String {
            let comps = calendar.dateComponents([.year, .month], from: startOfMonth)
            guard var dc = Optional(comps) else { return "" }
            dc.day = day
            guard let date = calendar.date(from: dc) else { return "" }
            let key = ISO8601DateFormatter().string(from: date).prefix(10)
            let dayEvts = eventsByDayCache[String(key)] ?? []
            for ev in dayEvts {
                if ev.isLocal   { return localRed }
                if ev.isWeather { return weatherBlue }
                let c = colorForCalendar(ev.calendarName)
                if !c.isEmpty { return c }
            }
            return dayEvts.isEmpty ? "" : brightText
        }
        let emptyCell = String(repeating: " ", count: colW)

        // Build all week rows
        var weekRows: [String] = []
        var dayCounter = 1
        var firstRow = String(repeating: " ", count: calIndent)
        for weekdayIdx in 1...7 {
            if weekdayIdx < startWeekday {
                firstRow += emptyCell
            } else {
                firstRow += calCell(day: dayCounter,
                                    eventColor: eventColorForDay(dayCounter))
                dayCounter += 1
            }
        }
        weekRows.append(firstRow)
        while dayCounter <= totalDays {
            var row = String(repeating: " ", count: calIndent)
            for _ in 1...7 {
                if dayCounter <= totalDays {
                    row += calCell(day: dayCounter,
                                   eventColor: eventColorForDay(dayCounter))
                    dayCounter += 1
                } else {
                    row += emptyCell
                }
            }
            weekRows.append(row)
        }

        // Print the month grid inside a rounded box
        print("╭" + String(repeating: "─", count: inner) + "╮")
        let mLeft = mPad / 2
        print("│" + String(repeating: " ", count: mLeft) + monthHeader +
              String(repeating: " ", count: mPad - mLeft) + "│")
        print("│" + dayLabelRow + "│")
        print("├" + String(repeating: "─", count: inner) + "┤")
        for row in weekRows {
            print("│\(row)│")
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")

        // ── Agenda box ──────────────────────────────────────────────────────
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM dd, yyyy"
        let agendaHeader = "AGENDA FOR: " + df.string(from: selectedDate).uppercased()
        let agendaPad = max(0, inner - 1 - agendaHeader.count)
        let dayEvents = getEventsForSelectedDay(calendar: calendar, startOfMonth: startOfMonth, selectedDay: selectedDay)

        print("╭" + String(repeating: "─", count: inner) + "╮")
        print("│ \(agendaHeader)\(String(repeating: " ", count: agendaPad))│")
        print("├" + String(repeating: "─", count: inner) + "┤")
        if dayEvents.isEmpty {
            let msg = "  No events scheduled for this day."
            print("│\(msg)\(String(repeating: " ", count: inner - msg.count))│")
        } else {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "hh:mm a"
            for (idx, ev) in dayEvents.enumerated() {
                let startStr    = ev.isAllDay ? "ALL DAY" : timeFormatter.string(from: ev.startTime)
                let endStr      = ev.isAllDay ? "" : " – " + timeFormatter.string(from: ev.endTime)
                let timeDisplay = ev.isAllDay ? "[\(startStr)]" : "[\(startStr)\(endStr)]"
                let calColor    = colorForCalendar(ev.calendarName)
                let calLabel    = ev.isLocal ? "Local" : ev.calendarName
                let labelColor  = ev.isLocal ? localRed : (ev.isWeather ? weatherBlue : calColor)
                let calRaw      = calLabel.isEmpty ? "" : "(\(calLabel)) "
                let calColored  = calLabel.isEmpty ? "" : "\(labelColor)(\(calLabel))\u{001B}[0m "
                // METAR events store converted °F temps in notes — show in red after title
                let isMetar     = !ev.notes.isEmpty && ev.notes.contains("°F")
                let tempSuffix  = isMetar ? " [\(ev.notes)]" : ""
                let line        = "  [\(idx + 1)]. \(timeDisplay) \(calRaw)\(ev.title)\(tempSuffix)"
                let linePad     = max(0, inner - line.count)
                let printLine   = isMetar
                    ? "  [\(idx + 1)]. \(timeDisplay) \(calColored)\(ev.title)\u{001B}[1;31m\(tempSuffix)\u{001B}[0m"
                    : "  [\(idx + 1)]. \(timeDisplay) \(calColored)\(ev.title)"
                print("│\(printLine)\(String(repeating: " ", count: linePad))│")
            }
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")

        printStandardFooter()
        printNavFooter()

        let keyInput = keyboard.readKey()

        switch keyInput {
        case .up:
            if let newDate = calendar.date(byAdding: .day, value: -7, to: selectedDate) { selectedDate = newDate }
        case .down:
            if let newDate = calendar.date(byAdding: .day, value: 7, to: selectedDate) { selectedDate = newDate }
        case .left:
            if let newDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) { selectedDate = newDate }
        case .right:
            if let newDate = calendar.date(byAdding: .day, value: 1, to: selectedDate) { selectedDate = newDate }
        case .enter:
            if !dayEvents.isEmpty {
                keyboard.disableRawMode()
                currentScreen = .viewEvent(event: dayEvents[0])
                return
            }
        case .escape:
            Thread.sleep(forTimeInterval: 0.05)
            let secondKey = keyboard.readKey()
            if case .escape = secondKey {
                keyboard.disableRawMode()
                returnToLauncher()
                return
            }
        case .char(let ch):
            if ch == "," {
                if let newDate = calendar.date(byAdding: .month, value: -1, to: selectedDate) { selectedDate = newDate }
            } else if ch == "." {
                if let newDate = calendar.date(byAdding: .month, value: 1, to: selectedDate) { selectedDate = newDate }
            } else if ch == "r" || ch == "R" {
                keyboard.disableRawMode()
                print("\nSyncing calendar...")
                executeExternalSyncHelper()
                loadEvents()
                loadLocalEvents()
                loadWeatherHistory()
                return
            } else if ch == "e" || ch == "E" {
                keyboard.disableRawMode()
                showAddEventScreen(preselectedDate: selectedDate)
                // showAddEventScreen already re-enables raw mode itself on every return path —
                // calling it again here would snapshot the already-raw state as "original" and
                // permanently break canonical/echo restoration for the rest of the session.
            } else if ch == "a" || ch == "A" {
                keyboard.disableRawMode()
                showAccountSetupScreen()
                // Same reasoning — showAccountSetupScreen guarantees raw mode is restored itself.
            } else if let num = Int(String(ch)), num >= 1 && num <= dayEvents.count {
                keyboard.disableRawMode()
                currentScreen = .viewEvent(event: dayEvents[num - 1])
                return
            } else {
                // Nav footer — [R] is Sync so [S] is free for Stocks here
                let lower = Character(ch.lowercased())
                let navMap: [Character: String] = [
                    "t": "swiftCONTACTS", "m": "swiftMAIL",
                    "n": "swiftNOTES",    "s": "swiftSTOCKS",
                    "v": "swiftVAULT"
                ]
                if let target = navMap[lower] {
                    keyboard.disableRawMode()
                    navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                    return
                } else if lower == "l" {
                    keyboard.disableRawMode()
                    returnToLauncher()
                    return
                }
            }
        }
        keyboard.disableRawMode()
    }
    
    func showViewEventScreen(event: CalendarEvent) {
        keyboard.enableRawMode()
        printStandardHeader()

        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy"
        let tf = DateFormatter()
        tf.dateFormat = "hh:mm a"

        let inner = 118
        func infoRow(_ label: String, _ value: String, colored: String? = nil) {
            let plain = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(value)"
            let display = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(colored ?? value)"
            print("│\(display)\(String(repeating: " ", count: max(0, inner - plain.count)))│")
        }

        let timeStr = event.isAllDay ? "All Day" : "\(tf.string(from: event.startTime)) – \(tf.string(from: event.endTime))"
        let cleanLocation = event.location.replacingOccurrences(of: "\\n", with: ", ")

        print("╭" + String(repeating: "─", count: inner) + "╮")
        infoRow("Title",    event.title)
        infoRow("Date",     df.string(from: event.startTime))
        infoRow("Time",     timeStr)
        if !cleanLocation.isEmpty  { infoRow("Location", cleanLocation) }
        if !event.calendarName.isEmpty { infoRow("Calendar", event.calendarName) }
        let hasWeather = event.decodedWeather != nil && !(event.decodedWeather ?? "").isEmpty
        // For METAR/TAF events, `notes` holds only the converted °F temp — folded into the
        // Conditions line below instead of a separate Notes row. Non-weather events keep the
        // Notes row exactly as before.
        if !event.notes.isEmpty && !hasWeather { infoRow("Notes", event.notes) }
        if hasWeather {
            let decoded = event.decodedWeather!
            let tempRed   = "\u{001B}[1;31m"
            let colorReset = "\u{001B}[0m"

            var plainSegments = decoded.components(separatedBy: " · ")
            var displaySegments = plainSegments
            if !event.notes.isEmpty {
                // Temp goes first, highlighted red to catch the eye
                plainSegments.insert(event.notes, at: 0)
                displaySegments.insert("\(tempRed)\(event.notes)\(colorReset)", at: 0)
            }

            // decoded can run long on a busy report (multiple wind/visibility/sky/phenomena
            // segments) — infoRow prints one fixed-width row, so wrap on the " · " separators
            // rather than let a long line overflow the box border. Track plain (for width
            // math) and display (with the red temp escape codes) versions in parallel, since
            // ANSI codes count toward String.count but aren't visible in the terminal.
            let maxValueWidth = inner - 2 - 16  // matches infoRow's "  " + 16-char label layout
            var wrapPlain: [String] = []
            var wrapDisplay: [String] = []
            var curPlain = ""
            var curDisplay = ""
            for (p, d) in zip(plainSegments, displaySegments) {
                let candidatePlain = curPlain.isEmpty ? p : "\(curPlain) · \(p)"
                if candidatePlain.count > maxValueWidth && !curPlain.isEmpty {
                    wrapPlain.append(curPlain)
                    wrapDisplay.append(curDisplay)
                    curPlain = p
                    curDisplay = d
                } else {
                    curPlain = candidatePlain
                    curDisplay = curDisplay.isEmpty ? d : "\(curDisplay) · \(d)"
                }
            }
            if !curPlain.isEmpty {
                wrapPlain.append(curPlain)
                wrapDisplay.append(curDisplay)
            }
            for i in 0..<wrapPlain.count {
                infoRow(i == 0 ? "Conditions" : "", wrapPlain[i], colored: wrapDisplay[i])
            }
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")
        print("")
        printStandardFooter(keys: "[E] Edit  |  [D] Delete  |  [A] Accounts  |  ESC: Back")
        printNavFooter()

        let keyInput = keyboard.readKey()
        if case .escape = keyInput { currentScreen = .monthView }
        if case .char(let ch) = keyInput {
            let lower = Character(ch.lowercased())
            if lower == "d" {
                keyboard.disableRawMode()
                print("\n Delete \"\(event.title)\"? (y/n): ", terminator: "")
                if let confirm = readLine(), confirm.lowercased() == "y" {
                    events.removeAll { $0.id == event.id }
                    rebuildEventsByDayCache()
                    saveEvents()
                    // local_events.json is the authoritative store loadLocalEvents() re-reads on
                    // every sync (and at startup) — without rewriting it here too, a deleted local
                    // event survives in that file and gets re-appended right back into `events`.
                    saveLocalEvents()
                    CalendarDebugLogger.log("Event deleted locally: \(event.id)", category: "CALENDAR")
                    currentScreen = .monthView
                    return
                }
                keyboard.enableRawMode()
            } else if lower == "e" {
                keyboard.disableRawMode()
                showEditEventScreen(event)
                // showEditEventScreen re-enables raw mode itself before every return path.
                currentScreen = .monthView
            } else if lower == "a" {
                keyboard.disableRawMode()
                showAccountSetupScreen()
                // Same reasoning — showAccountSetupScreen guarantees raw mode is restored itself.
                currentScreen = .monthView
            } else {
                let navMap: [Character: String] = [
                    "t": "swiftCONTACTS", "m": "swiftMAIL",
                    "n": "swiftNOTES",    "s": "swiftSTOCKS",
                    "v": "swiftVAULT"
                ]
                if let target = navMap[lower] {
                    keyboard.disableRawMode()
                    navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                    return
                } else if lower == "l" {
                    keyboard.disableRawMode()
                    returnToLauncher()
                    return
                }
            }
        }
        keyboard.disableRawMode()
    }
    
    // MARK: - Core Utilities Logic
    
    // Rebuilt once per render rather than scanning the full events array up to 32 times per
    // render (31 day-marker checks + 1 for the agenda) — trivially fast either way for a
    // personal calendar's event count, but this is a cleaner shape that scales better and only
    // does one pass over `events` regardless of how many days are being checked.
    private var eventsByDayCache: [String: [CalendarEvent]] = [:]
    private let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Calendar.current.timeZone
        return f
    }()
    
    private func dayKey(_ date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }
    
    private func rebuildEventsByDayCache() {
        var index: [String: [CalendarEvent]] = [:]
        for ev in events {
            index[dayKey(ev.startTime), default: []].append(ev)
        }
        eventsByDayCache = index
    }
    
    private func checkEventsOnDay(_ day: Int, calendar: Calendar, baseDate: Date) -> Bool {
        var targetComponents = calendar.dateComponents([.year, .month], from: baseDate)
        targetComponents.day = day
        guard let targetDate = calendar.date(from: targetComponents) else { return false }
        return !(eventsByDayCache[dayKey(targetDate)]?.isEmpty ?? true)
    }
    
    private func getEventsForSelectedDay(calendar: Calendar, startOfMonth: Date, selectedDay: Int) -> [CalendarEvent] {
        var targetComponents = calendar.dateComponents([.year, .month], from: startOfMonth)
        targetComponents.day = selectedDay
        guard let targetDate = calendar.date(from: targetComponents) else { return [] }
        
        let matches = eventsByDayCache[dayKey(targetDate)] ?? []
        return matches.sorted(by: { $0.startTime < $1.startTime })
    }
    
    // MARK: - External Process Controller Task
    
    func executeExternalSyncHelper() {
        let scriptURL = resolveAppDataDirectory().appendingPathComponent("calendar_sync.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            print("\u{001B}[91mError: calendar_sync.py not found at \(scriptURL.path)\u{001B}[0m")
            lastSyncStatus = "calendar_sync.py not found"
            lastSyncWasError = true
            CalendarDebugLogger.log("Sync failed: script not found at \(scriptURL.path)", category: "SYNC-ERR")
            return
        }
        
        let process = Process()
        // /usr/bin/env resolves python3 from PATH rather than assuming it's at exactly
        // /usr/bin/python3 — more portable across systems where it's installed via Homebrew etc.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path]
        // The script writes calendar.json using a relative path — running it with this as its
        // working directory keeps that write landing in the same place Swift reads it from,
        // regardless of whatever directory swiftCALENDAR itself was launched from.
        process.currentDirectoryURL = resolveAppDataDirectory()
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                print("\u{001B}[92mSuccess: Helper application sync cycle succeeded cleanly.\u{001B}[0m")
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd-yy hh:mm a"
                lastSyncStatus = "Synced \(formatter.string(from: Date()).uppercased())"
                lastSyncWasError = false
                CalendarDebugLogger.log("Sync succeeded", category: "SYNC")
            } else {
                print("\u{001B}[91mNotice: External sync engine returned non-zero code (\(process.terminationStatus)).\u{001B}[0m")
                lastSyncStatus = "Sync failed (exit code \(process.terminationStatus))"
                lastSyncWasError = true
                CalendarDebugLogger.log("Sync failed with exit code \(process.terminationStatus)", category: "SYNC-ERR")
            }
        } catch {
            print("\u{001B}[91mFatal: Failed to execute external process task thread: \(error)\u{001B}[0m")
            lastSyncStatus = "Sync failed: \(error.localizedDescription)"
            lastSyncWasError = true
            CalendarDebugLogger.log("Sync process launch failed: \(error.localizedDescription)", category: "SYNC-ERR")
        }
    }
    
    // MARK: - Data Persistence
    
    func saveEvents() {
        do { 
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(events)
            try data.write(to: fileURL) 
        } catch { 
            print("Persistence Encode Error: \(error)") 
            CalendarDebugLogger.log("Save failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }
    
    func loadEvents() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            events = try decoder.decode([CalendarEvent].self, from: data)
            rebuildEventsByDayCache()
        } catch {
            print("Persistence Decode Error: \(error)")
            CalendarDebugLogger.log("Load failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }

    func loadLocalEvents() {
        guard FileManager.default.fileExists(atPath: localEventsURL.path) else { return }
        do {
            let data = try Data(contentsOf: localEventsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let local = try decoder.decode([CalendarEvent].self, from: data)
            // Remove any old locals from events, then append current locals
            events.removeAll { $0.isLocal }
            events.append(contentsOf: local)
            rebuildEventsByDayCache()
        } catch {
            CalendarDebugLogger.log("Local events load failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }

    func loadWeatherHistory() {
        guard FileManager.default.fileExists(atPath: weatherHistoryURL.path) else { return }
        do {
            let data = try Data(contentsOf: weatherHistoryURL)
            // metar_history.json is a dict keyed by "STATION|YYYY-MM-DD" — decode
            // as [String: CalendarEvent] and take the values. This file is written
            // exclusively by calendar_sync.py; swiftCALENDAR only ever reads it.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let history = try decoder.decode([String: CalendarEvent].self, from: data)
            events.removeAll { $0.isWeather }
            events.append(contentsOf: history.values.map { var e = $0; e.isWeather = true; return e })
            rebuildEventsByDayCache()
        } catch {
            CalendarDebugLogger.log("Weather history load failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }

    func saveLocalEvents() {
        let local = events.filter { $0.isLocal }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(local)
            try data.write(to: localEventsURL)
        } catch {
            CalendarDebugLogger.log("Local events save failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }

    // MARK: - Add Event Screen

    func showAddEventScreen(preselectedDate: Date? = nil) {
        keyboard.disableRawMode()
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()

        let inner = 118
        print("╭" + String(repeating: "─", count: inner) + "╮")
        let title = "  ADD EVENT"
        print("│\(title)\(String(repeating: " ", count: inner - title.count))│")
        print("├" + String(repeating: "─", count: inner) + "┤")
        print("│  Leave any field blank and press Enter to cancel.                                                                    │")
        print("╰" + String(repeating: "─", count: inner) + "╯")
        print("")

        // Title
        print(" Event title: ", terminator: "")
        guard let evTitle = readLine(), !evTitle.isEmpty else {
            keyboard.enableRawMode(); return
        }

        // Calendar name always defaults to Local — events created in-app
        // don't sync back to Outlook or Apple so offering a choice is misleading
        let calName = "Local"

        // Date — pre-filled from selected calendar date if available
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MM/dd/yyyy"
        let evDate: Date
        if let pre = preselectedDate {
            let preStr = dateFmt.string(from: pre)
            print(" Date (MM/DD/YYYY) [\(preStr)]: ", terminator: "")
            let input = readLine() ?? ""
            if input.isEmpty {
                evDate = pre
            } else if let parsed = dateFmt.date(from: input) {
                evDate = parsed
            } else {
                print(" Invalid date format. Press Enter.")
                _ = readLine(); keyboard.enableRawMode(); return
            }
        } else {
            print(" Date (MM/DD/YYYY): ", terminator: "")
            guard let dateStr = readLine(), !dateStr.isEmpty else {
                keyboard.enableRawMode(); return
            }
            guard let parsed = dateFmt.date(from: dateStr) else {
                print(" Invalid date format. Press Enter.")
                _ = readLine(); keyboard.enableRawMode(); return
            }
            evDate = parsed
        }

        // All day?
        print(" All day? (y/n): ", terminator: "")
        let allDayStr = (readLine() ?? "").lowercased()
        let isAllDay = allDayStr == "y" || allDayStr == "yes"

        var startTime = evDate
        var endTime   = Calendar.current.date(byAdding: .hour, value: 1, to: evDate) ?? evDate

        if !isAllDay {
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "hh:mm a"
            timeFmt.locale = Locale(identifier: "en_US_POSIX")

            print(" Start time (hh:mm AM/PM): ", terminator: "")
            if let sStr = readLine(), !sStr.isEmpty,
               let st = timeFmt.date(from: sStr.uppercased()) {
                let sc = Calendar.current.dateComponents([.hour, .minute], from: st)
                startTime = Calendar.current.date(bySettingHour: sc.hour ?? 9,
                                                   minute: sc.minute ?? 0,
                                                   second: 0, of: evDate) ?? evDate
            }
            print(" End time   (hh:mm AM/PM): ", terminator: "")
            if let eStr = readLine(), !eStr.isEmpty,
               let et = timeFmt.date(from: eStr.uppercased()) {
                let ec = Calendar.current.dateComponents([.hour, .minute], from: et)
                endTime = Calendar.current.date(bySettingHour: ec.hour ?? 10,
                                                 minute: ec.minute ?? 0,
                                                 second: 0, of: evDate) ?? evDate
            }
        }

        // Notes
        print(" Notes (optional): ", terminator: "")
        let evNotes = readLine() ?? ""

        var newEvent = CalendarEvent()
        newEvent.title        = evTitle
        newEvent.calendarName = calName
        newEvent.startTime    = startTime
        newEvent.endTime      = endTime
        newEvent.isAllDay     = isAllDay
        newEvent.notes        = evNotes
        newEvent.isLocal      = true

        events.append(newEvent)
        rebuildEventsByDayCache()
        saveLocalEvents()
        CalendarDebugLogger.log("Local event added: \(evTitle)", category: "CALENDAR")

        print("\n\u{001B}[1;32m Event '\(evTitle)' added.\u{001B}[0m Press Enter to return.")
        _ = readLine()
        keyboard.enableRawMode()
    }
    
    // MARK: - Edit Event Screen
    
    /// Prompts for each field pre-filled with the event's current value; blank Enter keeps it as-is.
    /// Guarantees raw mode is re-enabled on every return path, same as showAddEventScreen, so callers
    /// can trust the terminal state without re-toggling it themselves.
    func showEditEventScreen(_ event: CalendarEvent) {
        keyboard.disableRawMode()
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()

        let inner = 118
        print("╭" + String(repeating: "─", count: inner) + "╮")
        let title = "  EDIT EVENT"
        print("│\(title)\(String(repeating: " ", count: inner - title.count))│")
        print("├" + String(repeating: "─", count: inner) + "┤")
        let hint = "  Press Enter on any field to keep its current value."
        print("│\(hint)\(String(repeating: " ", count: inner - hint.count))│")
        print("╰" + String(repeating: "─", count: inner) + "╯")
        print("")
        
        guard event.isLocal else {
            print(" This event was synced from a calendar feed and can't be edited here — only")
            print(" locally-created events support editing. Press Enter to return.")
            _ = readLine()
            keyboard.enableRawMode()
            return
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MM/dd/yyyy"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "hh:mm a"
        timeFmt.locale = Locale(identifier: "en_US_POSIX")

        // Title
        print(" Event title [\(event.title)]: ", terminator: "")
        let titleInput = readLine() ?? ""
        let newTitle = titleInput.isEmpty ? event.title : titleInput

        // Date
        let curDateStr = dateFmt.string(from: event.startTime)
        print(" Date (MM/DD/YYYY) [\(curDateStr)]: ", terminator: "")
        let dateInput = readLine() ?? ""
        var newDate = event.startTime
        if !dateInput.isEmpty {
            if let parsed = dateFmt.date(from: dateInput) {
                newDate = parsed
            } else {
                print(" Invalid date format — keeping \(curDateStr). Press Enter.")
                _ = readLine()
            }
        }

        // All day?
        let curAllDayStr = event.isAllDay ? "Yes" : "No"
        print(" All day? [\(curAllDayStr)] (y/n): ", terminator: "")
        let allDayInput = (readLine() ?? "").lowercased()
        let newIsAllDay = allDayInput.isEmpty ? event.isAllDay : (allDayInput == "y" || allDayInput == "yes")

        var newStart = newDate
        var newEnd   = newDate

        if !newIsAllDay {
            let curStartStr = timeFmt.string(from: event.startTime)
            let curEndStr   = timeFmt.string(from: event.endTime)

            print(" Start time (hh:mm AM/PM) [\(curStartStr)]: ", terminator: "")
            let startInput = readLine() ?? ""
            let startComponents: DateComponents
            if !startInput.isEmpty, let st = timeFmt.date(from: startInput.uppercased()) {
                startComponents = Calendar.current.dateComponents([.hour, .minute], from: st)
            } else {
                startComponents = Calendar.current.dateComponents([.hour, .minute], from: event.startTime)
            }
            newStart = Calendar.current.date(bySettingHour: startComponents.hour ?? 9,
                                              minute: startComponents.minute ?? 0,
                                              second: 0, of: newDate) ?? newDate

            print(" End time   (hh:mm AM/PM) [\(curEndStr)]: ", terminator: "")
            let endInput = readLine() ?? ""
            let endComponents: DateComponents
            if !endInput.isEmpty, let et = timeFmt.date(from: endInput.uppercased()) {
                endComponents = Calendar.current.dateComponents([.hour, .minute], from: et)
            } else {
                endComponents = Calendar.current.dateComponents([.hour, .minute], from: event.endTime)
            }
            newEnd = Calendar.current.date(bySettingHour: endComponents.hour ?? 10,
                                            minute: endComponents.minute ?? 0,
                                            second: 0, of: newDate) ?? newDate
        }

        // Notes
        let curNotesStr = event.notes.isEmpty ? "None" : event.notes
        print(" Notes [\(curNotesStr)]: ", terminator: "")
        let notesInput = readLine() ?? ""
        let newNotes = notesInput.isEmpty ? event.notes : notesInput

        if let idx = events.firstIndex(where: { $0.id == event.id }) {
            events[idx].title      = newTitle
            events[idx].startTime  = newStart
            events[idx].endTime    = newEnd
            events[idx].isAllDay   = newIsAllDay
            events[idx].notes      = newNotes
            rebuildEventsByDayCache()
            saveLocalEvents()
            CalendarDebugLogger.log("Local event edited: \(event.id)", category: "CALENDAR")
        }

        print("\n\u{001B}[1;32m Event '\(newTitle)' updated.\u{001B}[0m Press Enter to return.")
        _ = readLine()
        keyboard.enableRawMode()
    }

    // MARK: - Account Setup Screen

    func showAccountSetupScreen() {
        keyboard.disableRawMode()
        var selectedIdx = 0

        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()

            let inner = 118
            print("╭" + String(repeating: "─", count: inner) + "╮")
            let hdr = "  CALENDAR ACCOUNT SETUP"
            print("│\(hdr)\(String(repeating: " ", count: inner - hdr.count))│")
            print("├" + String(repeating: "─", count: inner) + "┤")

            if calendarAccounts.isEmpty {
                let msg = "  No accounts configured. Press [A] to add your first calendar feed."
                print("│\(msg)\(String(repeating: " ", count: inner - msg.count))│")
            } else {
                for (i, acct) in calendarAccounts.enumerated() {
                    let ptr     = i == selectedIdx ? " -> " : "    "
                    let status  = acct.enabled ? "\u{001B}[1;32m●\u{001B}[0m Active  " : "\u{001B}[2m○ Off    \u{001B}[0m"
                    let color   = colorForCalendar(acct.name)
                    let colName = acct.colorIndex >= 0 && acct.colorIndex < calendarColorPalette.count
                        ? calendarColorPalette[acct.colorIndex].name : "None"
                    let urlTrunc = acct.url.count > 60 ? String(acct.url.prefix(57)) + "..." : acct.url
                    let namePart = "\(ptr)\(color)\(acct.name)\u{001B}[0m"
                    let namePlain = "\(ptr)\(acct.name)"
                    let right   = "  \(status)\(urlTrunc)"
                    let rightPlain = "  ● Active  \(urlTrunc)"
                    let colorTag = "  Color: \(color)\(colName)\u{001B}[0m"
                    let colorTagPlain = "  Color: \(colName)"
                    let pad = max(0, inner - namePlain.count - rightPlain.count - colorTagPlain.count)
                    print("│\(namePart)\(right)\(String(repeating: " ", count: pad))\(colorTag)│")
                }
            }
            print("╰" + String(repeating: "─", count: inner) + "╯")
            print("")
            printStandardFooter(keys: "↑/↓: Select | ENTER: Edit | A: Add | D: Delete | T: Toggle | ESC: Back")
            printNavFooter()

            keyboard.enableRawMode()
            let key = keyboard.readKey()
            keyboard.disableRawMode()

            switch key {
            case .escape:
                keyboard.enableRawMode()
                return
            case .up:
                if selectedIdx > 0 { selectedIdx -= 1 }
            case .down:
                if selectedIdx < calendarAccounts.count - 1 { selectedIdx += 1 }
            case .char(let ch):
                let lower = Character(ch.lowercased())
                if lower == "a" {
                    addAccountPrompt()
                } else if lower == "d" && !calendarAccounts.isEmpty {
                    print("\n Delete '\(calendarAccounts[selectedIdx].name)'? (y/n): ", terminator: "")
                    if (readLine() ?? "").lowercased() == "y" {
                        calendarAccounts.remove(at: selectedIdx)
                        if selectedIdx >= calendarAccounts.count { selectedIdx = max(0, calendarAccounts.count - 1) }
                        saveConfig()
                    }
                } else if lower == "t" && !calendarAccounts.isEmpty {
                    calendarAccounts[selectedIdx].enabled.toggle()
                    saveConfig()
                } else if lower == "l" {
                    keyboard.enableRawMode()
                    returnToLauncher(); return
                } else {
                    let navMap: [Character: String] = [
                        "c": "swiftCALENDAR", "m": "swiftMAIL",
                        "n": "swiftNOTES",    "s": "swiftSTOCKS",
                        "v": "swiftVAULT"
                    ]
                    if let target = navMap[lower] {
                        keyboard.enableRawMode()
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                        return
                    }
                }
            case .enter:
                if !calendarAccounts.isEmpty {
                    editAccountPrompt(index: selectedIdx)
                }
            default: break
            }
        }
    }

    private func addAccountPrompt() {
        print("\n Account type: [1] ICS Feed  [2] METAR  [3] TAF (forecast): ", terminator: "")
        let typeInput = readLine() ?? "1"
        let acctType: String
        switch typeInput.trimmingCharacters(in: .whitespaces) {
        case "2": acctType = "metar"
        case "3": acctType = "taf"
        default:  acctType = "ics"
        }

        print(" Account name (e.g. Outlook, METAR CLT, TAF CLT): ", terminator: "")
        guard let name = readLine(), !name.isEmpty else { return }

        if acctType == "metar" || acctType == "taf" {
            print(" Airport code (e.g. KCLT, KRDU): ", terminator: "")
        } else {
            print(" ICS URL: ", terminator: "")
        }
        guard let url = readLine(), !url.isEmpty else { return }

        print(" ", terminator: "")
        for (i, c) in calendarColorPalette.enumerated() {
            print("\(c.ansi)[\(i + 1)] \(c.name)\u{001B}[0m  ", terminator: "")
        }
        print("")
        print(" Color (1-7, or 0 for none): ", terminator: "")
        let colorIdx = (Int(readLine() ?? "0") ?? 0) - 1
        var acct = CalendarAccount()
        acct.name  = name
        acct.url   = (acctType == "metar" || acctType == "taf") ? url.uppercased() : url
        acct.type  = acctType
        acct.colorIndex = (colorIdx >= 0 && colorIdx < calendarColorPalette.count) ? colorIdx : -1
        if acctType == "taf" {
            print(" Latitude for NWS temps (e.g. 35.2271, Enter to skip): ", terminator: "")
            let latIn = readLine() ?? ""
            print(" Longitude for NWS temps (e.g. -80.8431, Enter to skip): ", terminator: "")
            let lonIn = readLine() ?? ""
            if !latIn.isEmpty && !lonIn.isEmpty {
                acct.lat = latIn.trimmingCharacters(in: .whitespaces)
                acct.lon = lonIn.trimmingCharacters(in: .whitespaces)
            }
        }
        calendarAccounts.append(acct)
        saveConfig()
        print(" \u{001B}[1;32mAccount '\(name)' added.\u{001B}[0m")
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func editAccountPrompt(index: Int) {
        let acct = calendarAccounts[index]
        print("\n Name [\(acct.name)]: ", terminator: "")
        let newName = readLine() ?? ""
        print(" URL  [\(acct.url.prefix(60))...]: ", terminator: "")
        let newURL = readLine() ?? ""
        print(" ", terminator: "")
        for (i, c) in calendarColorPalette.enumerated() {
            print("\(c.ansi)[\(i + 1)] \(c.name)\u{001B}[0m  ", terminator: "")
        }
        print("")
        print(" Color (1-7, 0=none) [current: \(acct.colorIndex + 1)]: ", terminator: "")
        let colorInput = readLine() ?? ""
        if !newName.isEmpty  { calendarAccounts[index].name = newName }
        if !newURL.isEmpty   { calendarAccounts[index].url  = newURL }
        if let ci = Int(colorInput) {
            calendarAccounts[index].colorIndex = (ci >= 1 && ci <= 8) ? ci - 1 : -1
        }
        saveConfig()
        print(" \u{001B}[1;32mSaved.\u{001B}[0m")
        Thread.sleep(forTimeInterval: 0.5)
    }
}


// MARK: - App Navigation

func navigateToApp(_ folder: String, args: [String]) {
    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    term.c_lflag |= tcflag_t(ECHO) | tcflag_t(ICANON)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
    let execPath = CommandLine.arguments[0]
    let suiteDir = URL(fileURLWithPath: execPath).deletingLastPathComponent().deletingLastPathComponent()
    let targetDir = suiteDir.appendingPathComponent(folder)
    let binaryPath = targetDir.appendingPathComponent(folder).path
    guard FileManager.default.fileExists(atPath: binaryPath) else {
        print("\n Error: binary not found at \(binaryPath). Press Enter.")
        _ = readLine(); return
    }
    if chdir(targetDir.path) != 0 { print("Error: chdir failed"); exit(1) }
    var cArgs: [UnsafeMutablePointer<CChar>?] = [binaryPath.withCString { strdup($0) }]
    for arg in args { cArgs.append(arg.withCString { strdup($0) }) }
    cArgs.append(nil)
    execv(binaryPath, &cArgs)
    print("Error: execv failed for \(folder)"); exit(1)
}

func returnToLauncher() { navigateToApp("swiftCORE", args: []) }

func printNavFooter(currentApp: String = "swiftCALENDAR") {
    let inner = 118
    // [S] Sync key changed to [R] (Refresh) so [S] is free for Stocks nav — consistent with all other apps.
    let navItems: [(key: String, label: String, folder: String)] = [
        ("T", "Contacts", "swiftCONTACTS"),
        ("C", "Calendar", "swiftCALENDAR"),
        ("M", "Mail",     "swiftMAIL"),
        ("N", "Notes",    "swiftNOTES"),
        ("S", "Stocks",   "swiftSTOCKS"),
        ("V", "Vault",    "swiftVAULT"),
    ]
    let plainParts = navItems.map { "[\($0.key)] \($0.label)" } + ["[L] Logout"]
    let plainNav   = plainParts.joined(separator: "  ")
    let navPad     = max(0, (inner - plainNav.count) / 2)
    var colored = ""
    for item in navItems {
        let label = "[\(item.key)] \(item.label)"
        colored += item.folder == currentApp
            ? "\u{001B}[1;32m\(label)\u{001B}[0m  "
            : "\u{001B}[2m\(label)\u{001B}[0m  "
    }
    colored += "\u{001B}[1;31m[L] Logout\u{001B}[0m"
    print("╭" + String(repeating: "─", count: inner) + "╮")
    print("│" + String(repeating: " ", count: navPad) + colored +
          String(repeating: " ", count: inner - navPad - plainNav.count) + "│")
    print("╰" + String(repeating: "─", count: inner) + "╯")
}

// MARK: - App Execution Trigger

let runner = CalendarManager()
runner.run()