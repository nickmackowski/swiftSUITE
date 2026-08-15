// ═══════════════════════════════════════════════════════════════
// APP: swiftCALENDAR
// Calendar with ICS, METAR, and TAF support
// File: swiftCALENDAR/source_code/sccm.main.swift
// Updated: 2026-08-15
// ═══════════════════════════════════════════════════════════════

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
    /// logs/ subfolder next to the binary — new for v3.0 (previously the log file sat loose
    /// beside the binary). Created on first access if it doesn't exist yet. Account config and
    /// other data files are unaffected and stay exactly where they were.
    static let logsDir: URL = {
        let dir = resolveAppDataDirectory().appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// One rotated log file per app launch, timestamped at process start. Swift only evaluates
    /// a `static let` closure once per process lifetime, so every log() call within this run
    /// writes to the same file — no per-call rotation logic needed.
    static let logURL: URL = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ts = formatter.string(from: Date())
        return logsDir.appendingPathComponent("swiftcalendar_\(ts).log")
    }()

    /// Keeps only the most recent 5 log files, matching swiftADMIN.py's existing build-log
    /// retention exactly (prune_logs()/MAX_LOGS=5). Called after every write rather than once
    /// at launch — cheap enough for a personal tool's logging frequency, and avoids any
    /// lazy-static-initialization timing edge cases around when the current file first appears.
    private static func pruneOldLogs(keep: Int = 5) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { return }
        let logs = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if logs.count > keep {
            for old in logs.prefix(logs.count - keep) {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }
    
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
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        pruneOldLogs()
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
    var isBirthday: Bool = false   // true = computed live from swiftCONTACTS' birthdayMonthDay,
                                    // never read from or written to disk — same reasoning as isWeather
    var isDue: Bool = false        // true = computed live from swiftNOTES' dueDate (due-date marker
                                    // or its 3-day-advance reminder) — never read from or written to disk
    var decodedWeather: String? = nil  // plain-English METAR/TAF decode for the detail view only —
                                        // agenda/title keeps the raw code. nil for non-weather events.
                                        // Optional, so a missing key in older calendar.json entries or
                                        // regular ICS events decodes safely as nil (no CodingKeys
                                        // exclusion needed, unlike isWeather — see note below).

    // isWeather/isBirthday/isDue are intentionally omitted here. Swift's synthesized Decodable requires
    // a JSON key for every listed property regardless of its default value, so including them
    // would break decoding of calendar.json and metar_history.json entirely (neither file
    // contains those keys). Leaving them out of CodingKeys means they're skipped during
    // decode/encode and simply keep their default (false) until the relevant load function sets
    // them explicitly (loadWeatherHistory(), loadBirthdayOverlay(), loadDueDateOverlay()).
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

/// known_airports.json schema: ICAO -> {display, airportName, iata, lat, lon}. Pre-seeded with
/// 439 entries (US carrier destinations); hand-edited directly to add more, documented in the
/// README. Used for the METAR/TAF location-name decoding in the detail view.
struct AirportInfo: Codable {
    var display: String = ""
    var airportName: String = ""
    var iata: String = ""
    var lat: Double = 0
    var lon: Double = 0
}

func loadKnownAirports() -> [String: AirportInfo] {
    let url = resolveAppDataDirectory().appendingPathComponent("known_airports.json")
    guard let data = try? Data(contentsOf: url),
          let airports = try? JSONDecoder().decode([String: AirportInfo].self, from: data) else {
        return [:]
    }
    return airports
}

// Color palette — 8 choices for assigning to calendars
// Color palette — 7 choices for assigning to calendars. Four colors are reserved for
// system-computed overlays and deliberately excluded from this picker: Red (local events),
// Blue (weather/METAR-TAF), Yellow (due-date/reminder), Purple (birthday). Fixed alongside this
// pass: Blue used to still be pickable here despite weatherBlue below using the exact same ANSI
// code (\u{001B}[1;34m) — a real collision, not just a reservation on paper. Silver was
// considered but dropped — reads as a barely-different shade next to white UI text elsewhere.
let calendarColorPalette: [(name: String, ansi: String)] = [
    ("Cyan",    "\u{001B}[1;36m"),
    ("Green",   "\u{001B}[1;32m"),
    ("Magenta", "\u{001B}[1;35m"),
    ("Orange",  "\u{001B}[38;5;208m"),
    ("Pink",    "\u{001B}[1;38;5;211m"),
    ("Teal",    "\u{001B}[1;38;5;30m"),
    ("Mint",    "\u{001B}[1;38;5;121m"),
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
    
    /// Same as readKey(), but returns nil if no key arrives within timeoutSeconds instead of
    /// blocking forever — lets a caller repaint (e.g. to show live sync progress) while still
    /// waiting for input. Passing nil falls back to a plain blocking read.
    func waitForKey(timeoutSeconds: Double?) -> CalKey? {
        guard let timeoutSeconds = timeoutSeconds else {
            return readKey()
        }
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let timeoutMs = Int32(max(0, timeoutSeconds) * 1000)
        let ready = poll(&pfd, 1, timeoutMs)
        guard ready > 0 else { return nil } // 0 = timed out, <0 = interrupted/error
        return readKey()
    }
}

// MARK: - Application Core Logic

class CalendarManager {
    var events: [CalendarEvent] = []
    var calendarAccounts: [CalendarAccount] = []
    let localEventsURL    = resolveAppDataDirectory().appendingPathComponent("local_events.json")
    let weatherHistoryURL = resolveAppDataDirectory().appendingPathComponent("metar_history.json")
    let configURL      = resolveAppDataDirectory().appendingPathComponent("calendar_accounts.json")
    // Loaded once per launch, lazily — known_airports.json never changes during a run.
    lazy var knownAirports: [String: AirportInfo] = loadKnownAirports()
    var currentScreen: CalScreen = .monthView
    var running = true
    // Set true after the very first sync completes each launch. While false, showMonthView()
    // draws once with whatever was already on disk from the last session, then triggers the
    // sync and redraws — matching swiftSTOCKS' own "render immediately with last-known data,
    // then fill in fresh data" pattern, rather than showing a blank/spinner-only screen for the
    // whole wait.
    var hasSyncedThisLaunch = false
    
    var selectedDate = Date()
    let keyboard = CalKeyboardReader()
    let fileURL = resolveAppDataDirectory().appendingPathComponent("calendar.json")

    func colorForCalendar(_ name: String) -> String {
        guard let acct = calendarAccounts.first(where: { $0.name == name }) else { return "" }
        // METAR/TAF accounts always render blue regardless of colorIndex — matching the same
        // reserved-color logic used for actual event rendering in showMonthView(). Checked here
        // too so the account setup screen's name/color-tag display is consistent with reality,
        // rather than showing "None" for a color that's actually always applied.
        if acct.type == "metar" || acct.type == "taf" {
            return "\u{001B}[1;38;5;75m"
        }
        guard acct.colorIndex >= 0 && acct.colorIndex < calendarColorPalette.count else { return "" }
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
        loadBirthdayOverlay()
        loadDueDateOverlay()
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
        let titleText = "swiftCALENDAR v3.01.08.03c"  // plain for layout; colored below
        let sidePadding = (innerWidth - titleText.count) / 2
        var titleLineChars = Array(repeating: " ", count: innerWidth)
        for (i, ch) in dateString.enumerated() where i < innerWidth { titleLineChars[i] = String(ch) }
        for (i, ch) in titleText.enumerated() { titleLineChars[sidePadding + i] = String(ch) }
        // "swift" plain white; "CALENDAR" solid pink
        titleLineChars[sidePadding + 0] = "\u{001B}[1;97ms\u{001B}[0m"
        titleLineChars[sidePadding + 1] = "\u{001B}[1;97mw\u{001B}[0m"
        titleLineChars[sidePadding + 2] = "\u{001B}[1;97mi\u{001B}[0m"
        titleLineChars[sidePadding + 3] = "\u{001B}[1;97mf\u{001B}[0m"
        titleLineChars[sidePadding + 4] = "\u{001B}[1;97mt\u{001B}[0m"
        titleLineChars[sidePadding + 5] = "\u{001B}[1;38;5;211mC\u{001B}[0m"
        titleLineChars[sidePadding + 6] = "\u{001B}[1;38;5;211mA\u{001B}[0m"
        titleLineChars[sidePadding + 7] = "\u{001B}[1;38;5;211mL\u{001B}[0m"
        titleLineChars[sidePadding + 8] = "\u{001B}[1;38;5;211mE\u{001B}[0m"
        titleLineChars[sidePadding + 9] = "\u{001B}[1;38;5;211mN\u{001B}[0m"
        titleLineChars[sidePadding + 10] = "\u{001B}[1;38;5;211mD\u{001B}[0m"
        titleLineChars[sidePadding + 11] = "\u{001B}[1;38;5;211mA\u{001B}[0m"
        titleLineChars[sidePadding + 12] = "\u{001B}[1;38;5;211mR\u{001B}[0m"
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
        rebuildEventsByDayCache()
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: selectedDate)
        guard let startOfMonth = calendar.date(from: components),
              let rangeOfDays = calendar.range(of: .day, in: .month, for: selectedDate) else {
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
        let secondLine = " \(events.count) Event\(events.count == 1 ? "" : "s") from \(calCount) Calendar\(calCount == 1 ? "" : "s")"
        print(secondLine)

        // ── Month grid box ──────────────────────────────────────────────────
        // 6-char indent + 7 columns * 16 chars = 118 inner width exactly
        let colW      = 16
        let calIndent = 6
        let inner     = 118
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
        let weatherBlue = "\u{001B}[1;38;5;75m"  // same — shared between grid and agenda, METAR history entries.
                                                  // Lighter sky-blue (256-color) rather than standard ANSI
                                                  // blue (1;34m) — the old shade was hard to read against a
                                                  // black terminal background.
        let birthdayPurple = "\u{001B}[38;5;135m"  // same — shared between grid and agenda, birthday overlay
        let dueYellow = "\u{001B}[1;33m"  // same — shared between grid and agenda, due-date overlay

        func calCell(day: Int, eventColor: String) -> String {
            let dayStr  = String(format: "%02d", day)
            let isSel   = day == selectedDay
            let isToday = day == todayDay
            let hasEvt  = !eventColor.isEmpty
            // Today gets a bold white "*" marker in the first spacer position — a color-
            // independent cue that's easy to spot even with all the overlay colors now in play
            // (birthdays, due-dates, weather, local events). Reuses existing cell width (16
            // chars total: 2-char day + 14-char spacer either way) rather than adding space, so
            // grid alignment is completely unaffected.
            let todayMarker = "\u{001B}[1;97m*\u{001B}[0m"
            let spacer = isToday
                ? todayMarker + String(repeating: " ", count: colW - 3)
                : String(repeating: " ", count: colW - 2)

            // Green background dropped — the * marker now does the "this is today" job on its
            // own. Cursor (isSel) still takes visual priority when it lands on today, showing
            // the same plain yellow used everywhere else the cursor sits, so cursor position
            // stays distinguishable from "today, not currently selected."
            if isSel              { return "\(yellowHL)\(dayStr)\(calReset)\(spacer)" }
            if isToday            { return "\(brightText)\(dayStr)\(calReset)\(spacer)" }
            if hasEvt             { return "\(eventColor)\(dayStr)\(calReset)\(spacer)" }
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
                if ev.isLocal    { return localRed }
                if ev.isWeather  { return weatherBlue }
                if ev.isBirthday { return birthdayPurple }
                if ev.isDue      { return dueYellow }
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
                let labelColor  = ev.isLocal ? localRed : (ev.isWeather ? weatherBlue : (ev.isBirthday ? birthdayPurple : (ev.isDue ? dueYellow : calColor)))
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

        if !hasSyncedThisLaunch {
            hasSyncedThisLaunch = true
            // The grid above just drew once using whatever was already on disk from the last
            // session — no enableRawMode() has been called yet at this point, deliberately.
            // performLaunchSync() runs here the same way it did inside init() in the version
            // that was confirmed to work cleanly: main-thread, no background thread, AND no
            // raw-mode terminal state active anywhere in the process yet. Once it returns,
            // reload everything and redraw immediately with fresh data, no keypress required.
            performLaunchSync()
            loadEvents()
            loadLocalEvents()
            loadWeatherHistory()
            loadBirthdayOverlay()
            loadDueDateOverlay()
            return
        }

        // Raw mode is enabled here, right before actually reading a key — not unconditionally
        // at the top of this function like every other screen in the app. This is deliberate:
        // by the time execution reaches this line, the one-time launch sync above has already
        // fully completed, so enableRawMode() is never called before or during it.
        keyboard.enableRawMode()
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
                    "v": "swiftVAULT",
                    "b": "swiftBASE"
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
        if !cleanLocation.isEmpty {
            // METAR/TAF location decoding: for weather events, `location` is just the bare ICAO
            // (e.g. "KCLT") — look it up in known_airports.json and show the real name/city
            // alongside it. Raw ICAO stays plain/white (it's literally in the raw data); the
            // bracketed portion is red, same convention as the temp conversion below — red
            // means "derived/decoded, not literally present in the raw feed." Falls back to the
            // bare ICAO unchanged if it's not in the pre-seeded list.
            if event.isWeather, let airport = knownAirports[cleanLocation.uppercased()] {
                let tempRed = "\u{001B}[1;31m"
                let reset = "\u{001B}[0m"
                let bracketText = "[\(airport.airportName) | \(airport.display)]"
                let plainLocation = "\(cleanLocation) \(bracketText)"
                let coloredLocation = "\(cleanLocation) \(tempRed)\(bracketText)\(reset)"
                infoRow("Location", plainLocation, colored: coloredLocation)
            } else {
                infoRow("Location", cleanLocation)
            }
        }
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
                    "v": "swiftVAULT",
                    "b": "swiftBASE"
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
        // Weather entries (METAR/TAF) always sort first, regardless of count — everything else
        // keeps its existing startTime ordering. Both are all-day events sharing the same
        // startTime, so without this, their relative order was really just whatever order they
        // happened to load in, not a deliberate choice.
        return matches.sorted { a, b in
            if a.isWeather != b.isWeather { return a.isWeather }
            return a.startTime < b.startTime
        }
    }
    
    // MARK: - External Process Controller Task
    
    func executeExternalSyncHelper(isSilent: Bool = false) {
        let scriptURL = resolveAppDataDirectory().appendingPathComponent("calendar_sync.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            if !isSilent { print("\u{001B}[91mError: calendar_sync.py not found at \(scriptURL.path)\u{001B}[0m") }
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
        // Explicitly redirected rather than left to inherit the parent's stdin — this script
        // never needs interactive input, and sharing the same tty as the app's own raw-mode
        // terminal reading is a real risk of interference, not just theoretical.
        process.standardInput = FileHandle.nullDevice
        // Also redirect stdout/stderr to a pipe rather than inheriting the parent's — otherwise
        // calendar_sync.py's own progress prints ("Fetching Family...", "METAR today...", etc.)
        // go straight to the same terminal, uncaptured, which visibly collides with the main
        // thread's own redraw loop while this runs on a background thread. Captured output goes
        // to the debug log instead — still available for diagnosis, not painted mid-animation.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                CalendarDebugLogger.log("calendar_sync.py output: \(output)", category: "SYNC")
            }
            if process.terminationStatus == 0 {
                if !isSilent { print("\u{001B}[92mSuccess: Helper application sync cycle succeeded cleanly.\u{001B}[0m") }
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd-yy hh:mm a"
                lastSyncStatus = "Synced \(formatter.string(from: Date()).uppercased())"
                lastSyncWasError = false
                CalendarDebugLogger.log("Sync succeeded", category: "SYNC")
            } else {
                if !isSilent { print("\u{001B}[91mNotice: External sync engine returned non-zero code (\(process.terminationStatus)).\u{001B}[0m") }
                lastSyncStatus = "Sync failed (exit code \(process.terminationStatus))"
                lastSyncWasError = true
                CalendarDebugLogger.log("Sync failed with exit code \(process.terminationStatus)", category: "SYNC-ERR")
            }
        } catch {
            if !isSilent { print("\u{001B}[91mFatal: Failed to execute external process task thread: \(error)\u{001B}[0m") }
            lastSyncStatus = "Sync failed: \(error.localizedDescription)"
            lastSyncWasError = true
            CalendarDebugLogger.log("Sync process launch failed: \(error.localizedDescription)", category: "SYNC-ERR")
        }
    }
    
    /// Checks for new remote-created calendar entries (c: routed messages via the shared
    /// notes_capture.py script in swiftNOTES/source_code/). Runs SYNCHRONOUSLY on the main
    /// thread as part of the manual [R] sync — deliberately NOT on a background thread via
    /// Thread.detachNewThread. That background-thread + Process() combination, running during
    /// init() on launch, was confirmed to be the actual cause of a real bug: it froze the
    /// account-setup screen's "1/2" selection with no visible echo, only ever reproducing when
    /// that background check was present. Forking a subprocess from a background thread in a
    /// multi-threaded program is a known category of subtle POSIX issue even with every file
    /// descriptor correctly redirected. Running this the exact same way executeExternalSyncHelper()
    /// already does (blocking, main thread, no separate thread) sidesteps that mechanism
    /// entirely — the brief blocking wait during [R] is already expected UX, same as the
    /// ICS/METAR/TAF sync it runs alongside.
    func checkRemoteCalendarEntriesSync() {
        let notesAppRoot = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftnotes")
        let accountsURL = notesAppRoot.appendingPathComponent("capture_accounts.json")
        let scriptURL = notesAppRoot.appendingPathComponent("source_code").appendingPathComponent("notes_capture.py")
        guard FileManager.default.fileExists(atPath: accountsURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path]
        process.currentDirectoryURL = resolveAppDataDirectory()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                CalendarDebugLogger.log("Remote entry check: \(output)", category: "REMOTE-ENTRY")
            }
        } catch {
            CalendarDebugLogger.log("Remote entry check failed to launch: \(error.localizedDescription)", category: "REMOTE-ENTRY-ERR")
        }
    }
    
    /// Runs the full sync — calendar_sync.py (ICS/METAR/TAF) plus the remote-entry check —
    /// entirely on the MAIN thread, with no background thread anywhere. This is a genuinely
    /// different approach from every previous attempt at this, which all used
    /// Thread.detachNewThread (matching swiftNOTES' own proven pattern) — and every one of
    /// those broke the account-setup screen's keyboard input, confirmed through repeated,
    /// deliberate testing, even when scoped to launch-only exactly like swiftNOTES. Since the
    /// confirmed common factor across every failure was forking a subprocess from a
    /// *non-main* thread, this sidesteps that specific mechanism: the subprocess itself still
    /// runs independently (that's what a subprocess does), but Swift never hands off to a
    /// second thread to wait on it. Instead, process.run() starts it non-blocking, and this
    /// function polls process.isRunning in a loop on the main thread, redrawing a spinner frame
    /// each pass — which is what makes the animation possible at all despite being sequential,
    /// blocking code. This runs from within init(), before run()'s loop ever calls
    /// enableRawMode() for the first time, so there is no raw-mode terminal reading happening
    /// anywhere in the process at any point during this function.
    /// Draws a static placeholder version of the current month's grid — day numbers and
    /// today's "*" marker only, no event colors or agenda, since nothing is loaded yet during
    /// this sync. Redrawn identically every spinner frame in performLaunchSync() below, so it
    /// reads as a stable, recognizable calendar shape behind the spinner rather than a jarring
    /// near-blank screen. Reuses the same layout constants (colW/calIndent/inner) as
    /// showMonthView()'s own grid so it's visually consistent with the real thing.
    private func drawSyncPlaceholderScreen(statusMessage: String, frame: String) {
        printStandardHeader()
        print(" CALENDAR: Loading...")
        print(" \u{001B}[1;36mStatus: [ \(frame) ] \(statusMessage)\u{001B}[0m")
        
        let colW = 16
        let calIndent = 6
        let inner = 118
        let calendar = Calendar.current
        let today = Date()
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        let monthHeader = monthFormatter.string(from: today).uppercased()
        let mPad = max(0, inner - monthHeader.count)
        let dayLabelRow = String(repeating: " ", count: calIndent) +
            ["SUN","MON","TUE","WED","THU","FRI","SAT"]
                .map { $0.padding(toLength: colW, withPad: " ", startingAt: 0) }.joined()
        
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)),
              let rangeOfDays = calendar.range(of: .day, in: .month, for: today) else { return }
        let startWeekday = calendar.component(.weekday, from: startOfMonth)
        let totalDays = rangeOfDays.count
        let todayDay = calendar.component(.day, from: today)
        let dimText = "\u{001B}[2m"
        let brightText = "\u{001B}[1;97m"
        let calReset = "\u{001B}[0m"
        
        func skeletonCell(day: Int) -> String {
            let dayStr = String(format: "%02d", day)
            let isToday = day == todayDay
            let todayMarker = "\u{001B}[1;97m*\u{001B}[0m"
            let spacer = isToday
                ? todayMarker + String(repeating: " ", count: colW - 3)
                : String(repeating: " ", count: colW - 2)
            return isToday ? "\(brightText)\(dayStr)\(calReset)\(spacer)" : "\(dimText)\(dayStr)\(calReset)\(spacer)"
        }
        let emptyCell = String(repeating: " ", count: colW)
        
        var weekRows: [String] = []
        var dayCounter = 1
        var firstRow = String(repeating: " ", count: calIndent)
        for weekdayIdx in 1...7 {
            if weekdayIdx < startWeekday { firstRow += emptyCell }
            else { firstRow += skeletonCell(day: dayCounter); dayCounter += 1 }
        }
        weekRows.append(firstRow)
        while dayCounter <= totalDays {
            var row = String(repeating: " ", count: calIndent)
            for _ in 1...7 {
                if dayCounter <= totalDays { row += skeletonCell(day: dayCounter); dayCounter += 1 }
                else { row += emptyCell }
            }
            weekRows.append(row)
        }
        
        print("╭" + String(repeating: "─", count: inner) + "╮")
        print("│" + String(repeating: " ", count: (inner - monthHeader.count) / 2) + monthHeader + String(repeating: " ", count: mPad - (inner - monthHeader.count) / 2) + "│")
        print("│" + dayLabelRow.padding(toLength: inner, withPad: " ", startingAt: 0) + "│")
        print("├" + String(repeating: "─", count: inner) + "┤")
        for row in weekRows {
            print("│" + row.padding(toLength: inner + (row.count - stripAnsi(row).count), withPad: " ", startingAt: 0) + "│")
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")
    }
    
    /// Strips ANSI escape codes to get the true visible length of a string — needed above since
    /// row.count includes invisible color-code characters that would otherwise throw off padding.
    private func stripAnsi(_ s: String) -> String {
        var result = ""
        var inEscape = false
        for ch in s {
            if ch == "\u{001B}" { inEscape = true; continue }
            if inEscape { if ch == "m" { inEscape = false }; continue }
            result.append(ch)
        }
        return result
    }
    
    func performLaunchSync() {
        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        var frameIdx = 0
        
        func pollUntilFinished(_ process: Process, statusMessage: String) {
            // Cursor save/restore (\u{001B}[s / \u{001B}[u) was tried first, to overwrite just
            // the "X Events..." line in place over the real stale calendar — but this terminal
            // doesn't honor those sequences reliably (confirmed: each frame just appended as
            // new text and scrolled the whole screen). Showing the actual stale data briefly
            // then clearing to blank was tried next — also unsatisfying, since it still went
            // blank partway through. Settled on a static skeleton grid instead (day numbers and
            // today's marker only, no event data) redrawn identically every frame — a stable,
            // recognizable calendar shape behind the spinner for the whole wait, no flash to
            // blank at any point.
            while process.isRunning {
                print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
                let frame = spinnerFrames[frameIdx % spinnerFrames.count]
                frameIdx += 1
                drawSyncPlaceholderScreen(statusMessage: statusMessage, frame: frame)
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        
        // Part 1: calendar_sync.py (ICS/METAR/TAF)
        let scriptURL = resolveAppDataDirectory().appendingPathComponent("calendar_sync.py")
        if FileManager.default.fileExists(atPath: scriptURL.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path]
            process.currentDirectoryURL = resolveAppDataDirectory()
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                pollUntilFinished(process, statusMessage: "Syncing calendar...")
                process.waitUntilExit() // finalizes exit status/reaps the process; returns
                                         // immediately since isRunning is already false by now
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                    CalendarDebugLogger.log("calendar_sync.py output: \(output)", category: "SYNC")
                }
                if process.terminationStatus == 0 {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM-dd-yy hh:mm a"
                    lastSyncStatus = "Synced \(formatter.string(from: Date()).uppercased())"
                    lastSyncWasError = false
                    CalendarDebugLogger.log("Sync succeeded", category: "SYNC")
                } else {
                    lastSyncStatus = "Sync failed (exit code \(process.terminationStatus))"
                    lastSyncWasError = true
                    CalendarDebugLogger.log("Sync failed with exit code \(process.terminationStatus)", category: "SYNC-ERR")
                }
            } catch {
                lastSyncStatus = "Sync failed: \(error.localizedDescription)"
                lastSyncWasError = true
                CalendarDebugLogger.log("Sync process launch failed: \(error.localizedDescription)", category: "SYNC-ERR")
            }
        } else {
            lastSyncStatus = "calendar_sync.py not found"
            lastSyncWasError = true
            CalendarDebugLogger.log("Sync failed: script not found at \(scriptURL.path)", category: "SYNC-ERR")
        }
        
        // Part 2: shared remote-entry check (c:/n: routing via notes_capture.py)
        let notesAppRoot = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftnotes")
        let accountsURL = notesAppRoot.appendingPathComponent("capture_accounts.json")
        let remoteScriptURL = notesAppRoot.appendingPathComponent("source_code").appendingPathComponent("notes_capture.py")
        if FileManager.default.fileExists(atPath: accountsURL.path),
           FileManager.default.fileExists(atPath: remoteScriptURL.path) {
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process2.arguments = ["python3", remoteScriptURL.path]
            process2.currentDirectoryURL = resolveAppDataDirectory()
            process2.standardInput = FileHandle.nullDevice
            let pipe2 = Pipe()
            process2.standardOutput = pipe2
            process2.standardError = pipe2
            
            do {
                try process2.run()
                pollUntilFinished(process2, statusMessage: "Checking for remote entries...")
                process2.waitUntilExit()
                let outputData2 = pipe2.fileHandleForReading.readDataToEndOfFile()
                if let output2 = String(data: outputData2, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output2.isEmpty {
                    CalendarDebugLogger.log("Remote entry check: \(output2)", category: "REMOTE-ENTRY")
                }
            } catch {
                CalendarDebugLogger.log("Remote entry check failed to launch: \(error.localizedDescription)", category: "REMOTE-ENTRY-ERR")
            }
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
            var loaded = try decoder.decode([CalendarEvent].self, from: data)
            // TAF is "ephemeral" per calendar_sync.py's own comment — it gets refreshed into
            // calendar.json on every sync like a regular ICS event, unlike METAR which persists
            // separately in metar_history.json (and gets isWeather=true explicitly in
            // loadWeatherHistory() below). That means TAF events arriving through THIS path
            // never got flagged as weather at all — they rendered in whatever color was picked
            // during account setup instead of the reserved weatherBlue, and didn't get the
            // METAR/TAF location decoding in the detail view either, since both check isWeather.
            // Fixed here: a TAF event always has decodedWeather populated (calendar_sync.py sets
            // it via decode_wx_code()), which a regular ICS event never does — safe, accurate
            // signal to flag it correctly on load.
            for i in loaded.indices {
                if let dw = loaded[i].decodedWeather, !dw.isEmpty {
                    loaded[i].isWeather = true
                }
            }
            events = loaded
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
            // as [String: CalendarEvent] and take the values. This file is written by
            // calendar_sync.py during normal syncs; swiftCALENDAR also writes to it directly,
            // but only via deleteMetarHistory() below, when explicitly asked to clear a
            // deleted account's history.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let history = try decoder.decode([String: CalendarEvent].self, from: data)
            // Only remove entries belonging to a currently-configured METAR account — NOT every
            // isWeather-flagged event. isWeather now also covers TAF events (loaded separately
            // via loadEvents(), flagged there since they have decodedWeather populated) — a
            // blanket `$0.isWeather` removal here was wiping those out too, since this function
            // runs right after loadEvents() in init(). Real bug found in testing: TAF events
            // disappeared specifically whenever metar_history.json existed, because this
            // function only returns early (skipping the removal entirely) when that file is
            // missing — that's why deleting the file "fixed" it.
            let metarAccountNames = Set(calendarAccounts.filter { $0.type == "metar" }.map { $0.name })
            events.removeAll { $0.isWeather && metarAccountNames.contains($0.calendarName) }
            events.append(contentsOf: history.values.map { var e = $0; e.isWeather = true; return e })
            rebuildEventsByDayCache()
        } catch {
            CalendarDebugLogger.log("Weather history load failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }
    
    /// Removes every entry belonging to a specific station from metar_history.json — called
    /// only when explicitly confirmed after deleting a METAR account. metar_history.json is
    /// deliberately persistent/upserted (see calendar_sync.py's own comment on WEATHER_FILE) so
    /// this cleanup never happens automatically as a side effect of anything else. Keys are
    /// "STATION|YYYY-MM-DD", so matching on a "STATION|" prefix is exact — no ambiguity with
    /// other stations that happen to share a substring.
    func deleteMetarHistory(forStation station: String) {
        guard FileManager.default.fileExists(atPath: weatherHistoryURL.path) else { return }
        do {
            let data = try Data(contentsOf: weatherHistoryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var history = try decoder.decode([String: CalendarEvent].self, from: data)
            let prefix = "\(station.uppercased())|"
            let removedCount = history.keys.filter { $0.uppercased().hasPrefix(prefix) }.count
            history = history.filter { !$0.key.uppercased().hasPrefix(prefix) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let newData = try encoder.encode(history)
            try newData.write(to: weatherHistoryURL)
            print(" \u{001B}[1;32mRemoved \(removedCount) historical METAR entr\(removedCount == 1 ? "y" : "ies") for \(station).\u{001B}[0m")
            CalendarDebugLogger.log("Deleted \(removedCount) metar_history.json entries for station \(station)", category: "CALENDAR")
            // Also clear it from the in-memory events array immediately, so it disappears from
            // the agenda/grid right away rather than waiting for the next launch.
            events.removeAll { $0.isWeather && $0.location.uppercased() == station.uppercased() }
            rebuildEventsByDayCache()
        } catch {
            print(" \u{001B}[91mCouldn't update metar_history.json: \(error.localizedDescription)\u{001B}[0m")
            CalendarDebugLogger.log("deleteMetarHistory failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }
    
    /// Reads swiftCONTACTS' contacts.json directly for birthdayMonthDay — plaintext, no
    /// decryption needed. Computes recurring all-day birthday events LIVE for a bounded window
    /// of years around today (currentYear ± 3) — never stored anywhere, recomputed fresh every
    /// launch, mirroring loadWeatherHistory()'s load-once-at-init pattern exactly.
    func loadBirthdayOverlay() {
        let contactsURL = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftcontacts")
            .appendingPathComponent("contacts.json")
        guard FileManager.default.fileExists(atPath: contactsURL.path) else { return }
        
        struct ContactBirthdayEntry: Codable {
            var firstName: String = ""
            var lastName: String = ""
            var birthdayMonthDay: String? = nil
        }
        // contacts.json is NOT a bare array — it's a wrapper object (kdfIterations, canary,
        // contacts, kdfSalt, formatVersion).
        struct ContactsFileForOverlay: Codable {
            var contacts: [ContactBirthdayEntry] = []
        }
        
        do {
            let data = try Data(contentsOf: contactsURL)
            let contactsFile = try JSONDecoder().decode(ContactsFileForOverlay.self, from: data)
            
            events.removeAll { $0.isBirthday }
            
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: Date())
            let yearRange = (currentYear - 3)...(currentYear + 3)
            
            var newBirthdayEvents: [CalendarEvent] = []
            for contact in contactsFile.contacts {
                guard let md = contact.birthdayMonthDay, !md.isEmpty else { continue }
                // Tolerates either "/" or "-" as the separator — real contacts.json data has
                // both, from before/after the format changed to match dob's "/" convention.
                let parts = md.split(whereSeparator: { $0 == "/" || $0 == "-" })
                guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
                      (1...12).contains(month), (1...31).contains(day) else { continue }
                
                let fullName = "\(contact.firstName) \(contact.lastName)".trimmingCharacters(in: .whitespaces)
                guard !fullName.isEmpty else { continue }
                
                for year in yearRange {
                    var comps = DateComponents()
                    comps.year = year
                    comps.month = month
                    comps.day = day
                    guard let eventDate = calendar.date(from: comps) else { continue }
                    
                    var event = CalendarEvent()
                    event.title = "It's \(fullName)'s Birthday"
                    event.startTime = eventDate
                    event.endTime = eventDate
                    event.isAllDay = true
                    event.calendarName = "Birthdays"
                    event.isBirthday = true
                    newBirthdayEvents.append(event)
                }
            }
            events.append(contentsOf: newBirthdayEvents)
            rebuildEventsByDayCache()
        } catch {
            CalendarDebugLogger.log("Birthday overlay load failed: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }
    
    /// Reads swiftNOTES' notes.json directly for dueDate — no decryption needed, dueDate/title/
    /// isArchived are all plaintext metadata; only encryptedBody stays encrypted, and this
    /// overlay never touches that. Computes a due-date marker plus a synthetic 3-day-advance
    /// reminder LIVE for every non-archived note with a due date, mirroring
    /// loadWeatherHistory()'s load-once-at-init pattern. Filters to isArchived == false.
    func loadDueDateOverlay() {
        let notesURL = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftnotes")
            .appendingPathComponent("notes.json")
        guard FileManager.default.fileExists(atPath: notesURL.path) else { return }
        
        // Minimal structs — only pull the fields this overlay needs. notes.json is a
        // NotebookFile wrapper (formatVersion, kdfSalt, kdfIterations, canary, notes,
        // lastBackupTimestamp); defining a struct with just `notes` and letting the decoder
        // ignore the rest is safe and simpler than modeling the whole file. dueDate is
        // deliberately Optional (Date?) — a note without a due date must decode to nil here, not
        // some default value, or every note would incorrectly show up on the calendar.
        struct NoteDueEntry: Codable {
            var title: String = ""
            var dueDate: Date? = nil
            var isArchived: Bool = false
        }
        struct NotebookFileForOverlay: Codable {
            var notes: [NoteDueEntry] = []
        }
        
        do {
            let data = try Data(contentsOf: notesURL)
            // notes.json uses Swift's DEFAULT JSONEncoder/Decoder (no custom
            // dateDecodingStrategy set anywhere in scn_main.swift) — Date fields are encoded as
            // raw seconds-since-2001-01-01 (Cocoa reference date), NOT ISO8601 strings.
            // Deliberately NOT using an .iso8601-configured decoder here, unlike
            // loadEvents()/loadWeatherHistory() above — using the wrong strategy would fail to
            // decode dueDate at all (a type mismatch, not just wrong values).
            let notebook = try JSONDecoder().decode(NotebookFileForOverlay.self, from: data)
            
            // TEMPORARY DIAGNOSTIC — remove once confirmed working against real capture data.
            let withDue = notebook.notes.filter { $0.dueDate != nil }
            CalendarDebugLogger.log("DIAGNOSTIC: loadDueDateOverlay() decoded \(notebook.notes.count) total notes, \(withDue.count) with a non-nil dueDate. Titles with due dates: \(withDue.map { "\($0.title) (archived=\($0.isArchived))" })", category: "DIAGNOSTIC")
            
            events.removeAll { $0.isDue }
            
            var newDueEvents: [CalendarEvent] = []
            for note in notebook.notes {
                guard let due = note.dueDate, !note.isArchived else { continue }
                let noteTitle = note.title.isEmpty ? "Untitled Note" : note.title
                
                var dueEvent = CalendarEvent()
                dueEvent.title = noteTitle
                dueEvent.startTime = due
                dueEvent.endTime = due
                dueEvent.isAllDay = true
                dueEvent.calendarName = "Due Dates"
                dueEvent.isDue = true
                newDueEvents.append(dueEvent)
                
                if let reminderDate = Calendar.current.date(byAdding: .day, value: -3, to: due) {
                    var reminderEvent = CalendarEvent()
                    reminderEvent.title = "Reminder: \(noteTitle) due in 3 days"
                    reminderEvent.startTime = reminderDate
                    reminderEvent.endTime = reminderDate
                    reminderEvent.isAllDay = true
                    reminderEvent.calendarName = "Due Dates"
                    reminderEvent.isDue = true
                    newDueEvents.append(reminderEvent)
                }
            }
            events.append(contentsOf: newDueEvents)
            rebuildEventsByDayCache()
        } catch {
            CalendarDebugLogger.log("Due-date overlay load failed: \(error.localizedDescription)", category: "STORAGE-ERR")
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
                    let colName: String
                    if acct.type == "metar" || acct.type == "taf" {
                        colName = "Blue"
                    } else if acct.colorIndex >= 0 && acct.colorIndex < calendarColorPalette.count {
                        colName = calendarColorPalette[acct.colorIndex].name
                    } else {
                        colName = "None"
                    }
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
            printStandardFooter(keys: "↑/↓: Select | ENTER: Edit | A: Add | D: Delete | X: Toggle | ESC: Back")
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
                    let acctToDelete = calendarAccounts[selectedIdx]
                    print("\n Delete '\(acctToDelete.name)'? (y/n): ", terminator: "")
                    if (readLine() ?? "").lowercased() == "y" {
                        calendarAccounts.remove(at: selectedIdx)
                        if selectedIdx >= calendarAccounts.count { selectedIdx = max(0, calendarAccounts.count - 1) }
                        saveConfig()
                        
                        // metar_history.json is deliberately persistent (upserted, never
                        // wholesale-overwritten by calendar_sync.py) — deleting the account
                        // alone never removes that station's past entries from it, unlike TAF
                        // events, which self-resolve on the next sync since calendar.json gets
                        // fully regenerated from currently-configured accounts. Ask rather than
                        // assume, since old history might still be worth keeping for reference.
                        if acctToDelete.type == "metar" {
                            print(" Also delete historical METAR data for \(acctToDelete.url)? (y/n): ", terminator: "")
                            if (readLine() ?? "").lowercased() == "y" {
                                deleteMetarHistory(forStation: acctToDelete.url)
                            }
                        }
                    }
                } else if lower == "x" && !calendarAccounts.isEmpty {
                    calendarAccounts[selectedIdx].enabled.toggle()
                    saveConfig()
                } else if lower == "l" {
                    keyboard.disableRawMode()
                    returnToLauncher(); return
                } else {
                    // [C] omitted deliberately — this IS swiftCALENDAR, so it's the current app,
                    // not a navigable target. Including it here caused a real bug: pressing C
                    // relaunched the app into itself instead of being a no-op.
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "m": "swiftMAIL",
                        "n": "swiftNOTES",    "s": "swiftSTOCKS",
                        "v": "swiftVAULT",
                    "b": "swiftBASE"
                ]
                    if let target = navMap[lower] {
                        keyboard.disableRawMode()
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

    /// Wraps readLine() with ESC-to-cancel support — returns nil if the user enters a literal
    /// ESC character or types "esc" (a discoverable fallback, since a genuine ESC keypress isn't
    /// always reliably captured by Swift's canonical-mode readLine() depending on terminal
    /// driver). Mirrors the same pattern already used in swiftNOTES' getStringInput().
    private func readLineOrEscape() -> String? {
        guard let input = readLine() else { return nil }
        if input == "\u{1B}" || input.lowercased() == "esc" { return nil }
        return input
    }
    
    private func addAccountPrompt() {
        print("\n \u{001B}[1;31m(Type 'esc' + Enter, or press Escape + Enter, to cancel)\u{001B}[0m")
        print(" Account type: [1] ICS Feed  [2] Aviation Weather (METAR + TAF): ", terminator: "")
        guard let typeInput = readLineOrEscape() else { print(" Cancelled."); return }
        let isAviationWeather = typeInput.trimmingCharacters(in: .whitespaces) == "2"
        
        if isAviationWeather {
            // Unified setup — one station ID creates both a METAR and a TAF account, auto-filling
            // lat/lon from known_airports.json when the ICAO is recognized. Replaces the old
            // separate "Add METAR" / "Add TAF" flows.
            print(" Airport Code (e.g. KCLT, KRDU): ", terminator: "")
            guard let rawCode = readLineOrEscape() else { print(" Cancelled."); return }
            guard !rawCode.isEmpty else { return }
            let stationID = rawCode.trimmingCharacters(in: .whitespaces).uppercased()
            
            var lat = ""
            var lon = ""
            if let airport = knownAirports[stationID] {
                lat = String(airport.lat)
                lon = String(airport.lon)
                print(" \u{001B}[1;32mFound \(airport.airportName) (\(airport.display)) — lat/lon auto-filled.\u{001B}[0m")
            } else {
                print(" \u{001B}[1;33m\(stationID) isn't in known_airports.json — enter lat/lon manually for NWS temps.\u{001B}[0m")
                print(" Latitude (e.g. 35.2271, Enter to skip): ", terminator: "")
                guard let latIn = readLineOrEscape() else { print(" Cancelled."); return }
                print(" Longitude (e.g. -80.8431, Enter to skip): ", terminator: "")
                guard let lonIn = readLineOrEscape() else { print(" Cancelled."); return }
                if !latIn.isEmpty && !lonIn.isEmpty {
                    lat = latIn.trimmingCharacters(in: .whitespaces)
                    lon = lonIn.trimmingCharacters(in: .whitespaces)
                }
            }
            
            var metarAcct = CalendarAccount()
            metarAcct.name = "METAR \(stationID)"
            metarAcct.url = stationID
            metarAcct.type = "metar"
            metarAcct.colorIndex = -1
            
            var tafAcct = CalendarAccount()
            tafAcct.name = "TAF \(stationID)"
            tafAcct.url = stationID
            tafAcct.type = "taf"
            tafAcct.colorIndex = -1
            tafAcct.lat = lat
            tafAcct.lon = lon
            
            calendarAccounts.append(metarAcct)
            calendarAccounts.append(tafAcct)
            saveConfig()
            print(" \u{001B}[1;32mAdded METAR + TAF for \(stationID).\u{001B}[0m")
            print(" Quit and relaunch swiftCALENDAR to pull in data for the new account.")
            Thread.sleep(forTimeInterval: 0.8)
            return
        }
        
        print(" Account name (e.g. Outlook): ", terminator: "")
        guard let name = readLineOrEscape() else { print(" Cancelled."); return }
        guard !name.isEmpty else { return }
        print(" ICS URL: ", terminator: "")
        guard let url = readLineOrEscape() else { print(" Cancelled."); return }
        guard !url.isEmpty else { return }

        print(" ", terminator: "")
        for (i, c) in calendarColorPalette.enumerated() {
            print("\(c.ansi)[\(i + 1)] \(c.name)\u{001B}[0m  ", terminator: "")
        }
        print("")
        print(" Color (1-\(calendarColorPalette.count), or 0 for none): ", terminator: "")
        guard let colorInput = readLineOrEscape() else { print(" Cancelled."); return }
        let colorIdx = (Int(colorInput) ?? 0) - 1
        var acct = CalendarAccount()
        acct.name  = name
        acct.url   = url
        acct.type  = "ics"
        acct.colorIndex = (colorIdx >= 0 && colorIdx < calendarColorPalette.count) ? colorIdx : -1
        calendarAccounts.append(acct)
        saveConfig()
        print(" \u{001B}[1;32mAccount '\(name)' added.\u{001B}[0m")
        print(" Quit and relaunch swiftCALENDAR to pull in data for the new account.")
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func editAccountPrompt(index: Int) {
        let acct = calendarAccounts[index]
        print("\n \u{001B}[1;31m(Type 'esc' + Enter, or press Escape + Enter, to cancel)\u{001B}[0m")
        print(" Name [\(acct.name)]: ", terminator: "")
        guard let newName = readLineOrEscape() else { print(" Cancelled."); return }
        print(" URL  [\(acct.url.prefix(60))...]: ", terminator: "")
        guard let newURL = readLineOrEscape() else { print(" Cancelled."); return }
        
        var newColorIndex = acct.colorIndex
        if acct.type == "metar" || acct.type == "taf" {
            // No color prompt for weather accounts — see the matching note in addAccountPrompt().
        } else {
            print(" ", terminator: "")
            for (i, c) in calendarColorPalette.enumerated() {
                print("\(c.ansi)[\(i + 1)] \(c.name)\u{001B}[0m  ", terminator: "")
            }
            print("")
            print(" Color (1-\(calendarColorPalette.count), 0=none) [current: \(acct.colorIndex + 1)]: ", terminator: "")
            guard let colorInput = readLineOrEscape() else { print(" Cancelled."); return }
            if let ci = Int(colorInput) {
                newColorIndex = (ci >= 1 && ci <= calendarColorPalette.count) ? ci - 1 : -1
            }
        }
        
        // Gathered everything successfully — commit all at once, only now. Nothing in
        // calendarAccounts[index] was touched until this point, so cancelling at any prompt
        // above leaves the existing account completely untouched, no partial edit possible.
        if !newName.isEmpty { calendarAccounts[index].name = newName }
        if !newURL.isEmpty  { calendarAccounts[index].url  = newURL }
        calendarAccounts[index].colorIndex = newColorIndex
        
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
        ("B", "Base",     "swiftBASE"),
        ("C", "Calendar", "swiftCALENDAR"),
        ("T", "Contacts", "swiftCONTACTS"),
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