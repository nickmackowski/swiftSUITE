// ═══════════════════════════════════════════════════════════════
// APP: swiftBASE
// Personal database app — an architectural copy of swiftCONTACTS
// (screen-stack navigation, workspace/search/card/edit flow), with
// two additions: user-definable fields per database, and the
// ability to keep multiple separate databases.
// File: swiftBASE/source_code/scb.main.swift
// Updated: 2026-08-15
// ═══════════════════════════════════════════════════════════════

import Foundation

// MARK: - App Storage Location
func resolveAppDataDirectory() -> URL {
    let executablePath = CommandLine.arguments.first ?? "."
    return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
}

// MARK: - Models
// Records carry their own UUID now (not just raw dictionaries) --
// needed for Edit to work reliably. Matching by full field-value
// equality (the first-pass approach) breaks the moment you're editing
// the very values you'd be matching against, and was already a known
// risk for Delete if two records ever happened to be identical.
struct BaseRecord: Codable, Equatable {
    var id: UUID = UUID()
    var values: [String: String] = [:]
}

// A field is now more than just a name -- hiddenFromCard lets a field
// stay fully present in the table/CSV/add-edit prompts while being
// omitted from the card view specifically, and an empty name represents
// a deliberate blank-line spacer for visually laying out the card (never
// shown as a table column, never prompted for a value, never exported).
struct BaseField: Codable, Equatable {
    var name: String = ""
    var hiddenFromCard: Bool = false

    var isBlankLine: Bool { name.isEmpty }
}

struct BaseDatabase: Codable {
    var id: UUID = UUID()
    var name: String = ""
    var fields: [BaseField] = []       // order drives card layout, table columns, and add/edit prompts
    var records: [BaseRecord] = []
    var lastBackupTimestamp: String? = nil
}

struct BaseFile: Codable {
    var databases: [BaseDatabase] = []
    var lastOpenedDatabaseID: UUID? = nil
    var lastFullBackupTimestamp: String? = nil
}

let baseDataURL = resolveAppDataDirectory().appendingPathComponent("base.json")

func loadBaseFile() -> BaseFile {
    guard let data = try? Data(contentsOf: baseDataURL),
          let file = try? JSONDecoder().decode(BaseFile.self, from: data) else {
        return BaseFile()
    }
    return file
}

func saveBaseFile(_ file: BaseFile) {
    guard let data = try? JSONEncoder().encode(file) else { return }
    try? data.write(to: baseDataURL)
}

func loadDatabases() -> [BaseDatabase] { loadBaseFile().databases }

func saveDatabases(_ databases: [BaseDatabase]) {
    var file = loadBaseFile()
    file.databases = databases
    saveBaseFile(file)
}

func setLastOpenedDatabase(_ id: UUID?) {
    var file = loadBaseFile()
    file.lastOpenedDatabaseID = id
    saveBaseFile(file)
}

// Backs up just ONE database (not the whole base.json) -- matching how
// swiftCONTACTS' own backup is scoped to Contacts alone, not Vault and
// Notes too. Saved as its own timestamped JSON file so Restore has
// something concrete to read back from.
func backupDatabase(_ database: BaseDatabase) -> Bool {
    let timestamp = DateFormatter()
    timestamp.dateFormat = "yyyyMMdd_HHmmss"
    let safeName = database.name.replacingOccurrences(of: " ", with: "_")
    let backupName = "\(safeName)_backup_\(timestamp.string(from: Date())).json"
    let backupURL = resolveAppDataDirectory().appendingPathComponent(backupName)
    guard let data = try? JSONEncoder().encode(database) else { return false }
    guard (try? data.write(to: backupURL)) != nil else { return false }

    let displayFormat = DateFormatter()
    displayFormat.dateFormat = "MM-dd-yy hh:mm a"
    var databases = loadDatabases()
    if let idx = databases.firstIndex(where: { $0.id == database.id }) {
        databases[idx].lastBackupTimestamp = displayFormat.string(from: Date())
        saveDatabases(databases)
    }
    return true
}

// Finds every backup file belonging to this specific database (matched by
// the same safe-name prefix backupDatabase() writes), newest first.
func listBackupFiles(for database: BaseDatabase) -> [URL] {
    let safeName = database.name.replacingOccurrences(of: " ", with: "_")
    let dir = resolveAppDataDirectory()
    guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return contents
        .filter { $0.lastPathComponent.hasPrefix("\(safeName)_backup_") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }   // filename timestamp sorts newest-first
}

// Replaces this database's fields/records with whatever's in the chosen
// backup file, keeping the database's own id and name intact.
func restoreDatabase(_ database: BaseDatabase, from backupURL: URL) -> Bool {
    guard let data = try? Data(contentsOf: backupURL),
          let restored = try? JSONDecoder().decode(BaseDatabase.self, from: data) else { return false }
    var databases = loadDatabases()
    guard let idx = databases.firstIndex(where: { $0.id == database.id }) else { return false }
    databases[idx].fields = restored.fields
    databases[idx].records = restored.records
    saveDatabases(databases)
    return true
}

// Backs up every database at once -- the whole base.json, not just one --
// tracked with its own suite-wide timestamp, separate from each
// database's individual backup timestamp.
func backupAllDatabases() -> Bool {
    let timestamp = DateFormatter()
    timestamp.dateFormat = "yyyyMMdd_HHmmss"
    let backupName = "swiftBASE_full_backup_\(timestamp.string(from: Date())).json"
    let backupURL = resolveAppDataDirectory().appendingPathComponent(backupName)
    guard let data = try? Data(contentsOf: baseDataURL) else { return false }
    guard (try? data.write(to: backupURL)) != nil else { return false }

    let displayFormat = DateFormatter()
    displayFormat.dateFormat = "MM-dd-yy hh:mm a"
    var file = loadBaseFile()
    file.lastFullBackupTimestamp = displayFormat.string(from: Date())
    saveBaseFile(file)
    return true
}

func listFullBackupFiles() -> [URL] {
    let dir = resolveAppDataDirectory()
    guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return contents
        .filter { $0.lastPathComponent.hasPrefix("swiftBASE_full_backup_") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
}

// Validates the backup actually decodes as a genuine BaseFile before
// overwriting anything -- a corrupt or unrelated JSON file landing on
// base.json would be far worse than just failing this restore attempt.
func restoreAllDatabases(from url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url),
          (try? JSONDecoder().decode(BaseFile.self, from: data)) != nil else { return false }
    guard (try? data.write(to: baseDataURL)) != nil else { return false }
    return true
}

func deleteDatabase(_ database: BaseDatabase) {
    var file = loadBaseFile()
    file.databases.removeAll { $0.id == database.id }
    if file.lastOpenedDatabaseID == database.id {
        file.lastOpenedDatabaseID = nil
    }
    saveBaseFile(file)
}

// Simple CSV export -- header row of field names, blank otherwise. Meant
// to be filled in externally then brought back in via Import.
func exportCSVTemplate(_ database: BaseDatabase) -> URL? {
    let safeName = database.name.replacingOccurrences(of: " ", with: "_")
    let url = resolveAppDataDirectory().appendingPathComponent("\(safeName)_template.csv")
    let header = database.fields.filter { !$0.isBlankLine }.map { "\"\($0.name.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",")
    guard (try? header.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
    return url
}

// Genuine CSV import -- first row is treated as headers matching field
// names (order doesn't need to match the database's own field order),
// each subsequent row becomes one record. Proper quote-aware parsing:
// a comma inside a quoted field (exactly what Excel produces for any
// value that itself contains a comma, e.g. a lens description like
// "Canon RF 24-70mm, f/2.8L") does NOT split the row, and a doubled
// quote ("") inside a quoted field is unescaped to a single literal
// quote -- both standard CSV/Excel behavior, not just a naive split.
func importCSV(_ database: BaseDatabase, from url: URL) -> Int {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
    let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard lines.count > 1 else { return 0 }

    func parseLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                if insideQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\"")   // escaped quote inside a quoted field
                    i += 1
                } else {
                    insideQuotes.toggle()  // entering or leaving a quoted field
                }
            } else if char == "," && !insideQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
            i += 1
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    let headers = parseLine(lines[0])
    var newRecords: [BaseRecord] = []
    for line in lines.dropFirst() {
        let cells = parseLine(line)
        var values: [String: String] = [:]
        for (i, header) in headers.enumerated() where i < cells.count {
            values[header] = cells[i]
        }
        newRecords.append(BaseRecord(values: values))
    }

    var databases = loadDatabases()
    if let idx = databases.firstIndex(where: { $0.id == database.id }) {
        databases[idx].records.append(contentsOf: newRecords)
        saveDatabases(databases)
    }
    return newRecords.count
}

func deleteAllRecords(_ database: BaseDatabase) {
    var databases = loadDatabases()
    if let idx = databases.firstIndex(where: { $0.id == database.id }) {
        databases[idx].records = []
        saveDatabases(databases)
    }
}

// MARK: - Raw Keyboard Reading
enum BaseKey {
    case up, down, enter, escape, number(Int)
    case other(Character)
}

class BaseKeyboardReader {
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
    func readKey() -> BaseKey {
        var buffer = [UInt8](repeating: 0, count: 3)
        let bytesRead = read(STDIN_FILENO, &buffer, 3)
        if bytesRead <= 0 { return .other("\0") }
        if buffer[0] == 27 {
            if bytesRead == 1 { return .escape }
            if buffer[1] == 91 {
                switch buffer[2] {
                case 65: return .up
                case 66: return .down
                default: return .escape
                }
            }
            return .escape
        }
        if buffer[0] == 10 { return .enter }
        let ch = Character(UnicodeScalar(buffer[0]))
        if let digit = ch.wholeNumberValue, ch.isNumber { return .number(digit) }
        return .other(ch)
    }
}

// MARK: - Footer (header moves into BaseApp below, since it needs telemetry state)
func colorizeFooterKeys(_ line: String) -> String {
    let segments = line.components(separatedBy: "|")
    let colored = segments.map { segment -> String in
        if let bracketRange = segment.range(of: "]"), segment.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let keyPart = String(segment[segment.startIndex..<bracketRange.upperBound])
            let rest = String(segment[bracketRange.upperBound...])
            return "\u{001B}[1;38;5;111m\(keyPart)\u{001B}[0m\(rest)"
        }
        guard let colonRange = segment.range(of: ": ") else { return segment }
        let keyPart = String(segment[segment.startIndex..<colonRange.lowerBound])
        let rest = String(segment[colonRange.lowerBound...])
        return "\u{001B}[1;38;5;111m\(keyPart)\u{001B}[0m\(rest)"
    }
    return colored.joined(separator: "|")
}

func printStandardFooter(keys: String) {
    let inner = 118
    let p = max(0, (inner - keys.count) / 2)
    let colored = colorizeFooterKeys(keys)
    print("╭" + String(repeating: "─", count: inner) + "╮")
    print("│" + String(repeating: " ", count: p) + colored + String(repeating: " ", count: inner - p - keys.count) + "│")
    print("╰" + String(repeating: "─", count: inner) + "╯")
}

func printNavFooter() {
    let inner = 118
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
        if item.folder == "swiftBASE" {
            colored += "\u{001B}[1;32m\(label)\u{001B}[0m  "
        } else {
            colored += "\u{001B}[2m\(label)\u{001B}[0m  "
        }
    }
    colored += "\u{001B}[1;31m[L] Logout\u{001B}[0m"
    print("╭" + String(repeating: "─", count: inner) + "╮")
    print("│" + String(repeating: " ", count: navPad) + colored +
          String(repeating: " ", count: inner - navPad - plainNav.count) + "│")
    print("╰" + String(repeating: "─", count: inner) + "╯")
}

func navMapLookup() -> [Character: String] {
    ["c": "swiftCALENDAR", "t": "swiftCONTACTS", "m": "swiftMAIL",
     "n": "swiftNOTES",    "s": "swiftSTOCKS",   "v": "swiftVAULT"]
}

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

// MARK: - Screen Stack
// Matches swiftCONTACTS' own navigation architecture directly: an enum
// of possible screens, a stack of them, run() switches on whatever's on
// top. navigate(to:) pushes, goBack() pops -- genuine back-navigation,
// not the ad-hoc nested-loops-with-return-values the first pass used.
enum BaseScreen {
    case databasePicker
    case globalSearch
    case globalUtilities
    case globalSelectResult(results: [(database: BaseDatabase, record: BaseRecord)], title: String)
    case createDatabase
    case workspace(database: BaseDatabase)
    case modify(database: BaseDatabase)
    case manageFields(database: BaseDatabase)
    case search(database: BaseDatabase)
    case selectResult(database: BaseDatabase, results: [BaseRecord], title: String)
    case viewRecord(database: BaseDatabase, record: BaseRecord)
    case addRecord(database: BaseDatabase)
    case editRecord(database: BaseDatabase, record: BaseRecord)
}

class BaseApp {
    var screenStack: [BaseScreen] = [.databasePicker]
    let keyboard = BaseKeyboardReader()
    var running = true

    // Telemetry passed between apps via execv() launch arguments -- matches
    // swiftCONTACTS' own machineName/uptime/cpuUsage/memUsage + parseLauncherArguments().
    var machineName: String = "macOS"
    var uptime: String = "Unknown"
    var cpuUsage: String = "0%"
    var memUsage: String = "0G"

    init() {
        parseLauncherArguments()
        // Always starts at the database picker now, rather than jumping
        // straight into the last-used database -- lastOpenedDatabaseID is
        // still tracked (see showDatabasePickerScreen) purely to pre-position
        // the cursor there, not to skip the picker entirely.
    }

    private func parseLauncherArguments() {
        let args = CommandLine.arguments
        if args.count >= 5 {
            machineName = args[1]
            uptime = args[2]
            cpuUsage = args[3]
            memUsage = args[4]
        }
    }

    // Matches swiftCONTACTS' printStandardHeader exactly -- title/date/time
    // line, then a second telemetry line (User/Connected/Uptime/CPU/Mem).
    // Needs to be a method (not a free function) since it reads instance
    // telemetry state.
    func printStandardHeader() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yy"
        let dateString = dateFormatter.string(from: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "hh:mm:ss a"
        let timeString = timeFormatter.string(from: now).uppercased()

        let innerWidth = 118
        let titleText = "swiftBASE v3.01.08.15c"
        let sidePadding = (innerWidth - titleText.count) / 2
        var titleLineChars = Array(repeating: " ", count: innerWidth)
        for (i, ch) in dateString.enumerated() where i < innerWidth { titleLineChars[i] = String(ch) }
        for (i, ch) in titleText.enumerated() { titleLineChars[sidePadding + i] = String(ch) }
        for (i, ch) in "swift".enumerated() {
            titleLineChars[sidePadding + i] = "\u{001B}[1;97m\(ch)\u{001B}[0m"
        }
        for (i, ch) in "BASE".enumerated() {
            titleLineChars[sidePadding + 5 + i] = "\u{001B}[1;38;5;111m\(ch)\u{001B}[0m"
        }
        let trailingCIndex = titleText.count - 1
        titleLineChars[sidePadding + trailingCIndex] = "\u{001B}[38;5;208mc\u{001B}[0m"
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

    func navigate(to screen: BaseScreen) {
        screenStack.append(screen)
    }

    func goBack() {
        if screenStack.count > 1 {
            screenStack.removeLast()
        }
    }

    // Entering OR switching to a database always resets to a clean 2-level
    // stack ([.databasePicker, .workspace]) rather than pushing on top of
    // whatever was already there. Without this, repeatedly switching
    // databases via Utilities would grow the stack indefinitely, and ESC
    // from a freshly-switched workspace would walk back through the
    // PREVIOUS database's old screens instead of reaching the picker.
    func openDatabase(_ db: BaseDatabase) {
        setLastOpenedDatabase(db.id)
        screenStack = [.databasePicker, .workspace(database: db)]
    }

    // Refetches a database by id from disk, so every screen always
    // reflects the latest saved state rather than a stale in-memory copy.
    func fresh(_ database: BaseDatabase) -> BaseDatabase? {
        loadDatabases().first(where: { $0.id == database.id })
    }

    func run() {
        while running {
            guard let currentScreen = screenStack.last else { break }
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")

            switch currentScreen {
            case .databasePicker:
                showDatabasePickerScreen()
            case .globalSearch:
                showGlobalSearchScreen()
            case .globalUtilities:
                showGlobalUtilitiesScreen()
            case .globalSelectResult(let results, let title):
                showGlobalResultsScreen(results: results, title: title)
            case .createDatabase:
                showCreateDatabaseScreen()
            case .workspace(let database):
                if let db = fresh(database) { showWorkspaceScreen(database: db) }
                else { goBack() }
            case .modify(let database):
                if let db = fresh(database) { showModifyScreen(database: db) }
                else { goBack() }
            case .manageFields(let database):
                if let db = fresh(database) { showManageFieldsScreen(database: db) }
                else { goBack() }
            case .search(let database):
                if let db = fresh(database) { showSearchScreen(database: db) }
                else { goBack() }
            case .selectResult(let database, let results, let title):
                if let db = fresh(database) { showResultsScreen(database: db, results: results, title: title) }
                else { goBack() }
            case .viewRecord(let database, let record):
                if let db = fresh(database) { showViewRecordScreen(database: db, record: record) }
                else { goBack() }
            case .addRecord(let database):
                if let db = fresh(database) { showAddRecordScreen(database: db) }
                else { goBack() }
            case .editRecord(let database, let record):
                if let db = fresh(database) { showEditRecordScreen(database: db, record: record) }
                else { goBack() }
            }
        }
    }

    // MARK: - Database Picker (now the app's home screen -- shows every
    // database in a grid matching the workspace's own visual style, rather
    // than auto-resuming straight into whichever was used last).
    func showDatabasePickerScreen() {
        let databases = loadDatabases()
        keyboard.enableRawMode()
        let greenBarBG = "\u{001B}[48;5;22m"
        let cReset = "\u{001B}[0m"

        // Pre-positions the cursor on whichever database was last used,
        // rather than always defaulting to the top -- keeps a little of
        // the old "picks up where you left off" feel without skipping
        // the grid itself.
        let lastID = loadBaseFile().lastOpenedDatabaseID
        var selectedIdx = databases.firstIndex(where: { $0.id == lastID }) ?? 0

        func lc(_ s: String, _ w: Int) -> String { String(s.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0) }

        while true {
            if selectedIdx >= databases.count { selectedIdx = max(0, databases.count - 1) }
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()

            let totalRecords = databases.reduce(0) { $0 + $1.records.count }
            let statusLeft = " swiftBASE: \(databases.count) Database\(databases.count == 1 ? "" : "s")"
            let statusRight = "● \(totalRecords) Total Record\(totalRecords == 1 ? "" : "s")"
            let statusPad = max(1, 119 - statusLeft.count - statusRight.count)
            print("\u{001B}[1;37m\(statusLeft)\u{001B}[0m\(String(repeating: " ", count: statusPad))\u{001B}[1;32m\(statusRight)\u{001B}[0m")

            let lastFullBackup = loadBaseFile().lastFullBackupTimestamp
            let backupText = " Last Backup: \(lastFullBackup ?? "Never")"
            let backedUp = lastFullBackup != nil
            let backupStatusText = backedUp ? "● Backed Up" : "● Never Backed Up"
            let backupStatusColor = backedUp ? "\u{001B}[1;32m" : "\u{001B}[1;33m"
            let backupPad = max(1, 119 - backupText.count - backupStatusText.count)
            print("\(backupText)\(String(repeating: " ", count: backupPad))\(backupStatusColor)\(backupStatusText)\u{001B}[0m")

            let headerRow = "  " + lc("#", 3) + lc("DATABASE", 40) + lc("RECORDS", 12) + lc("FIELDS", 12)
            print("╭" + String(repeating: "─", count: 118) + "╮")
            print("│\u{001B}[1;37m\(lc(headerRow, 118))\u{001B}[0m│")
            print("├" + String(repeating: "─", count: 118) + "┤")

            if databases.isEmpty {
                let msg = "  No databases yet. Press [A] to create your first one."
                print("│\(lc(msg, 118))│")
            } else {
                for (rowNum, db) in databases.enumerated() {
                    let rowText = "  " + lc("\(rowNum + 1)", 3) + lc(db.name, 40) + lc("\(db.records.count)", 12) + lc("\(db.fields.filter { !$0.isBlankLine }.count)", 12)
                    let padded = lc(rowText, 118)
                    if rowNum == selectedIdx {
                        print("│\u{001B}[7m\u{001B}[1m\(padded)\(cReset)│")
                    } else if (rowNum + 1) % 2 != 0 {
                        print("│\(greenBarBG)\(padded)\(cReset)│")
                    } else {
                        print("│\(padded)│")
                    }
                }
            }
            print("╰" + String(repeating: "─", count: 118) + "╯")
            printStandardFooter(keys: "ENTER/1-9: Open  |  [/] Search All  |  [A] Add Database  |  [D] Delete  |  [U] Utilities")
            printNavFooter()

            switch keyboard.readKey() {
            case .up: if !databases.isEmpty { selectedIdx = (selectedIdx == 0) ? databases.count - 1 : selectedIdx - 1 }
            case .down: if !databases.isEmpty { selectedIdx = (selectedIdx == databases.count - 1) ? 0 : selectedIdx + 1 }
            case .number(let num):
                if num >= 1 && num <= databases.count {
                    keyboard.disableRawMode()
                    openDatabase(databases[num - 1])
                    return
                }
            case .enter:
                if !databases.isEmpty {
                    keyboard.disableRawMode()
                    openDatabase(databases[selectedIdx])
                    return
                }
            case .escape:
                // Pure back-navigation now -- [L] on the nav footer already
                // covers logout, so ESC doesn't need to double as that too.
                // goBack() is already a safe no-op at the root of the stack.
                keyboard.disableRawMode()
                goBack()
                return
            case .other(let ch):
                if ch == "/" {
                    keyboard.disableRawMode()
                    navigate(to: .globalSearch)
                    return
                }
                let lower = Character(ch.lowercased())
                if lower == "a" {
                    keyboard.disableRawMode()
                    navigate(to: .createDatabase)
                    return
                } else if lower == "d" && !databases.isEmpty {
                    keyboard.disableRawMode()
                    let target = databases[selectedIdx]
                    print("\n Delete database '\(target.name)' and all \(target.records.count) of its record(s)? This cannot be undone. (y/n): ", terminator: "")
                    if (readLine() ?? "").lowercased() == "y" {
                        deleteDatabase(target)
                    }
                    // No navigate/goBack needed -- .databasePicker is still on
                    // top of the stack, so run()'s own loop re-enters this
                    // same function fresh, reloading the updated list.
                    return
                } else if lower == "u" {
                    keyboard.disableRawMode()
                    navigate(to: .globalUtilities)
                    return
                } else if let target = navMapLookup()[lower] {
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
    }

    // MARK: - Global Search (across every database at once)
    func showGlobalSearchScreen() {
        printStandardHeader()
        let title = ">>> swiftBASE GLOBAL SEARCH <<<"
        let pad = max(0, (118 - title.count) / 2)
        print(String(repeating: " ", count: pad) + title)
        print(String(repeating: "─", count: 118))
        print(" Searches every database at once. Enter search phrase: ", terminator: "")
        guard let query = readLine(), !query.isEmpty else { goBack(); return }

        let lowerQuery = query.lowercased()
        var matches: [(database: BaseDatabase, record: BaseRecord)] = []
        for db in loadDatabases() {
            for record in db.records where record.values.values.contains(where: { $0.lowercased().contains(lowerQuery) }) {
                matches.append((database: db, record: record))
            }
        }
        goBack()

        if matches.isEmpty {
            print("\n No records matched '\(query)' in any database.")
            print(" Press Enter to return...")
            _ = readLine()
        } else {
            navigate(to: .globalSelectResult(results: matches, title: "GLOBAL RESULTS FOR '\(query.uppercased())'"))
        }
    }

    func showGlobalResultsScreen(results: [(database: BaseDatabase, record: BaseRecord)], title: String) {
        var localIdx = 0
        keyboard.enableRawMode()

        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            let pad = max(0, (118 - title.count) / 2)
            print(String(repeating: " ", count: pad) + title)
            print(" (Press ESC to go back)\n")

            for (idx, match) in results.enumerated() {
                let isSelected = (idx == localIdx)
                let displayField = match.database.fields.first(where: { !$0.isBlankLine })?.name ?? ""
                let display = match.record.values[displayField] ?? "(untitled)"
                let content = "[\(idx + 1)]. \(display)  —  (\(match.database.name))"
                if isSelected {
                    let full = " -> " + content
                    let padded = full.padding(toLength: 118, withPad: " ", startingAt: 0)
                    print("\u{001B}[7m\u{001B}[1m\(padded)\u{001B}[0m")
                } else {
                    print("    " + content)
                }
            }
            print(String(repeating: "─", count: 118))
            printStandardFooter(keys: "ENTER/1-9: Open  |  ESC: Back")
            printNavFooter()

            switch keyboard.readKey() {
            case .up: if !results.isEmpty { localIdx = (localIdx == 0) ? results.count - 1 : localIdx - 1 }
            case .down: if !results.isEmpty { localIdx = (localIdx == results.count - 1) ? 0 : localIdx + 1 }
            case .number(let num):
                if !results.isEmpty && num >= 1 && num <= results.count {
                    keyboard.disableRawMode()
                    let match = results[num - 1]
                    navigate(to: .viewRecord(database: match.database, record: match.record))
                    return
                }
            case .enter:
                if !results.isEmpty {
                    keyboard.disableRawMode()
                    let match = results[localIdx]
                    navigate(to: .viewRecord(database: match.database, record: match.record))
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .other: break
            }
        }
    }

    // MARK: - Global Utilities (suite-wide concerns: Backup and Restore,
    // each offering all databases at once or a single selected one)
    func showGlobalUtilitiesScreen() {
        keyboard.enableRawMode()
        var selectedIdx = 0
        var message: String? = nil
        let items = ["Backup Database(s)", "Restore Database(s)", "Back to swiftBASE"]

        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            let title = ">>> swiftBASE UTILITIES <<<"
            let pad = max(0, (118 - title.count) / 2)
            print(String(repeating: " ", count: pad) + title)
            print(" Use Arrow Keys or type number selection")
            print("")
            for (idx, item) in items.enumerated() {
                let isSelected = (idx == selectedIdx)
                let content = "[\(idx + 1)]. \(item)"
                if isSelected {
                    let full = " -> " + content
                    let padded = full.padding(toLength: 118, withPad: " ", startingAt: 0)
                    print("\u{001B}[7m\u{001B}[1m\(padded)\u{001B}[0m")
                } else {
                    print("    " + content)
                }
            }
            if let msg = message {
                print("")
                print(" \u{001B}[1;32m\(msg)\u{001B}[0m")
            }
            print("")
            printStandardFooter(keys: "ENTER/1-3: Select  |  ESC: Back")

            switch keyboard.readKey() {
            case .up: selectedIdx = (selectedIdx == 0) ? items.count - 1 : selectedIdx - 1
            case .down: selectedIdx = (selectedIdx == items.count - 1) ? 0 : selectedIdx + 1
            case .number(let num):
                if num >= 1 && num <= items.count {
                    selectedIdx = num - 1
                    message = handleGlobalUtilityChoice(selectedIdx)
                    if message == "__RETURNED__" { return }
                }
            case .enter:
                message = handleGlobalUtilityChoice(selectedIdx)
                if message == "__RETURNED__" { return }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            default: break
            }
        }
    }

    private func handleGlobalUtilityChoice(_ idx: Int) -> String {
        switch idx {
        case 0:   // Backup
            keyboard.disableRawMode()
            print("\n [A]ll databases or [S]elect one? ", terminator: "")
            let choice = (readLine() ?? "").lowercased()
            if choice == "a" {
                keyboard.enableRawMode()
                return backupAllDatabases() ? "All databases backed up." : "Backup failed."
            } else if choice == "s" {
                let databases = loadDatabases()
                guard !databases.isEmpty else {
                    keyboard.enableRawMode()
                    return "No databases exist yet."
                }
                print("\n Select a database:")
                for (i, db) in databases.enumerated() { print("  [\(i + 1)] \(db.name)") }
                print(" Number (blank to cancel): ", terminator: "")
                guard let input = readLine(), let num = Int(input), num >= 1, num <= databases.count else {
                    keyboard.enableRawMode()
                    return "Cancelled."
                }
                keyboard.enableRawMode()
                let target = databases[num - 1]
                return backupDatabase(target) ? "Backed up '\(target.name)'." : "Backup failed."
            } else {
                keyboard.enableRawMode()
                return "Cancelled."
            }
        case 1:   // Restore
            keyboard.disableRawMode()
            print("\n [A]ll databases or [S]elect one? ", terminator: "")
            let choice = (readLine() ?? "").lowercased()
            if choice == "a" {
                let backups = listFullBackupFiles()
                guard !backups.isEmpty else {
                    keyboard.enableRawMode()
                    return "No full-suite backups found yet."
                }
                print("\n Available full backups:")
                for (i, url) in backups.enumerated() { print("  [\(i + 1)] \(url.lastPathComponent)") }
                print(" Restore which one? (number, blank to cancel): ", terminator: "")
                guard let input = readLine(), let num = Int(input), num >= 1, num <= backups.count else {
                    keyboard.enableRawMode()
                    return "Cancelled."
                }
                print(" This replaces EVERY database with what's in this backup. Confirm? (y/n): ", terminator: "")
                let confirmed = (readLine() ?? "").lowercased() == "y"
                keyboard.enableRawMode()
                guard confirmed else { return "Cancelled." }
                return restoreAllDatabases(from: backups[num - 1]) ? "All databases restored." : "Restore failed."
            } else if choice == "s" {
                let databases = loadDatabases()
                guard !databases.isEmpty else {
                    keyboard.enableRawMode()
                    return "No databases exist yet."
                }
                print("\n Select a database:")
                for (i, db) in databases.enumerated() { print("  [\(i + 1)] \(db.name)") }
                print(" Number (blank to cancel): ", terminator: "")
                guard let dbInput = readLine(), let dbNum = Int(dbInput), dbNum >= 1, dbNum <= databases.count else {
                    keyboard.enableRawMode()
                    return "Cancelled."
                }
                let target = databases[dbNum - 1]
                let backups = listBackupFiles(for: target)
                guard !backups.isEmpty else {
                    keyboard.enableRawMode()
                    return "No backups found for '\(target.name)' yet."
                }
                print("\n Available backups for '\(target.name)':")
                for (i, url) in backups.enumerated() { print("  [\(i + 1)] \(url.lastPathComponent)") }
                print(" Restore which one? (number, blank to cancel): ", terminator: "")
                guard let backupInput = readLine(), let backupNum = Int(backupInput), backupNum >= 1, backupNum <= backups.count else {
                    keyboard.enableRawMode()
                    return "Cancelled."
                }
                print(" This will replace all current fields/records in '\(target.name)'. Confirm? (y/n): ", terminator: "")
                let confirmed = (readLine() ?? "").lowercased() == "y"
                keyboard.enableRawMode()
                guard confirmed else { return "Cancelled." }
                return restoreDatabase(target, from: backups[backupNum - 1]) ? "Restored '\(target.name)'." : "Restore failed."
            } else {
                keyboard.enableRawMode()
                return "Cancelled."
            }
        case 2:
            keyboard.disableRawMode()
            goBack()
            return "__RETURNED__"
        default:
            return ""
        }
    }

    func showCreateDatabaseScreen() {
        printStandardHeader()
        let title = ">>> swiftBASE CREATE DATABASE <<<"
        let pad = max(0, (118 - title.count) / 2)
        print(String(repeating: " ", count: pad) + title + "\n")
        print(" Database name: ", terminator: "")
        guard let name = readLine(), !name.isEmpty else { goBack(); return }

        var fields: [BaseField] = []
        print("\n Define your fields, one at a time. Leave blank when done.\n")
        while true {
            let prompt = fields.isEmpty ? " Field 1 (required): " : " Field \(fields.count + 1) (blank to finish): "
            print(prompt, terminator: "")
            guard let input = readLine(), !input.isEmpty else { break }
            fields.append(BaseField(name: input))
        }
        guard !fields.isEmpty else {
            print("\n A database needs at least one field. Cancelled. Press Enter.")
            _ = readLine()
            goBack()
            return
        }

        var databases = loadDatabases()
        let newDB = BaseDatabase(name: name, fields: fields, records: [])
        databases.append(newDB)
        saveDatabases(databases)
        print("\n\u{001B}[1;32mDatabase '\(name)' created with \(fields.count) field(s).\u{001B}[0m Press Enter.")
        _ = readLine()
        openDatabase(newDB)
    }

    // MARK: - Workspace (home screen for a database) -- status header + table
    // with cursor-based row selection and alternating greenbar rows, matching
    // swiftCONTACTS' own .workspace screen exactly (48;5;22 background on odd
    // rows, reverse-video on the currently selected row, overriding the
    // stripe there). Shows up to 3 columns of the database's own fields --
    // Contacts' fixed 4 columns can't carry over literally since fields are
    // dynamic here -- rather than requiring a search before showing anything.
    func showWorkspaceScreen(database: BaseDatabase) {
        keyboard.enableRawMode()
        let maxVisibleRows = 9
        let visibleFields = Array(database.fields.filter { !$0.isBlankLine }.prefix(3))
        let greenBarBG = "\u{001B}[48;5;22m"
        let cReset = "\u{001B}[0m"
        var selectedIdx = 0

        func lc(_ s: String, _ w: Int) -> String { String(s.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0) }

        while true {
            let sorted = database.records.sorted {
                let sortField = database.fields.first(where: { !$0.isBlankLine })?.name ?? ""
                let a = $0.values[sortField] ?? ""
                let b = $1.values[sortField] ?? ""
                return a.lowercased() < b.lowercased()
            }
            if selectedIdx >= sorted.count { selectedIdx = max(0, sorted.count - 1) }
            let visible = Array(sorted.prefix(maxVisibleRows))

            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()

            let recordLabel = "\(database.records.count) Record\(database.records.count == 1 ? "" : "s") Stored"
            let rightText = "● \(database.fields.filter { !$0.isBlankLine }.count) Field\(database.fields.filter { !$0.isBlankLine }.count == 1 ? "" : "s") Defined"
            let statusPadding = max(1, 119 - " \(database.name.uppercased()): \(recordLabel)".count - rightText.count)
            print("\u{001B}[1;37m \(database.name.uppercased()):\u{001B}[0m \(recordLabel)\(String(repeating: " ", count: statusPadding))\u{001B}[1;32m\(rightText)\u{001B}[0m")

            let backupText = " Last Backup: \(database.lastBackupTimestamp ?? "Never")"
            let backedUp = database.lastBackupTimestamp != nil
            let backupStatusText = backedUp ? "● Backed Up" : "● Never Backed Up"
            let backupStatusColor = backedUp ? "\u{001B}[1;32m" : "\u{001B}[1;33m"
            let backupPadding = max(1, 119 - backupText.count - backupStatusText.count)
            print("\(backupText)\(String(repeating: " ", count: backupPadding))\(backupStatusColor)\(backupStatusText)\u{001B}[0m")

            let colWidth = visibleFields.isEmpty ? 0 : (110 / visibleFields.count)
            let headerRow = "  " + lc("#", 3) + visibleFields.map { lc($0.name.uppercased(), colWidth) }.joined()
            print("╭" + String(repeating: "─", count: 118) + "╮")
            print("│\u{001B}[1;37m\(lc(headerRow, 118))\u{001B}[0m│")
            print("├" + String(repeating: "─", count: 118) + "┤")

            if visible.isEmpty {
                let msg = "  No records yet. Press [A] to add one."
                print("│\(lc(msg, 118))│")
            } else {
                for (rowNum, record) in visible.enumerated() {
                    let rowText = "  " + lc("\(rowNum + 1)", 3) + visibleFields.map { lc(record.values[$0.name] ?? "", colWidth) }.joined()
                    let padded = lc(rowText, 118)
                    if rowNum == selectedIdx {
                        print("│\u{001B}[7m\u{001B}[1m\(padded)\(cReset)│")
                    } else if (rowNum + 1) % 2 != 0 {
                        print("│\(greenBarBG)\(padded)\(cReset)│")
                    } else {
                        print("│\(padded)│")
                    }
                }
            }
            print("╰" + String(repeating: "─", count: 118) + "╯")
            printStandardFooter(keys: "ENTER/1-9: View  |  [/] Search  |  [A] Add  |  [O] Modify  |  ESC: All Databases")
            printNavFooter()

            switch keyboard.readKey() {
            case .up:
                if !visible.isEmpty { selectedIdx = (selectedIdx == 0) ? visible.count - 1 : selectedIdx - 1 }
            case .down:
                if !visible.isEmpty { selectedIdx = (selectedIdx == visible.count - 1) ? 0 : selectedIdx + 1 }
            case .number(let num):
                if num >= 1 && num <= visible.count {
                    keyboard.disableRawMode()
                    navigate(to: .viewRecord(database: database, record: visible[num - 1]))
                    return
                }
            case .enter:
                if !visible.isEmpty {
                    keyboard.disableRawMode()
                    navigate(to: .viewRecord(database: database, record: visible[selectedIdx]))
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .other(let ch):
                if ch == "/" {
                    keyboard.disableRawMode()
                    navigate(to: .search(database: database))
                    return
                }
                let lower = Character(ch.lowercased())
                if lower == "a" {
                    keyboard.disableRawMode()
                    navigate(to: .addRecord(database: database))
                    return
                } else if lower == "o" {
                    keyboard.disableRawMode()
                    navigate(to: .modify(database: database))
                    return
                } else if let target = navMapLookup()[lower] {
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
    }

    // MARK: - Utilities (matches swiftCONTACTS' own .dbUtilities screen)
    // Creating and switching databases live here rather than being scattered
    // across the workspace itself.
    func showModifyScreen(database: BaseDatabase) {
        keyboard.enableRawMode()
        var selectedIdx = 0
        var message: String? = nil

        let items = [
            "Export CSV Template",
            "Import from CSV",
            "Delete All Records",
            "Manage Fields",
            "Back to swiftBASE",
        ]

        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            let title = ">>> swiftBASE MODIFY \(database.name.uppercased()) <<<"
            let pad = max(0, (118 - title.count) / 2)
            print(String(repeating: " ", count: pad) + title)
            print(" Use Arrow Keys or type number selection")
            print("")
            for (idx, item) in items.enumerated() {
                let isSelected = (idx == selectedIdx)
                let content = "[\(idx + 1)]. \(item)"
                if isSelected {
                    let full = " -> " + content
                    let padded = full.padding(toLength: 118, withPad: " ", startingAt: 0)
                    print("\u{001B}[7m\u{001B}[1m\(padded)\u{001B}[0m")
                } else {
                    print("    " + content)
                }
            }
            if let msg = message {
                print("")
                print(" \u{001B}[1;32m\(msg)\u{001B}[0m")
            }
            print("")
            printStandardFooter(keys: "ENTER/1-5: Select  |  ESC: Back")

            switch keyboard.readKey() {
            case .up: selectedIdx = (selectedIdx == 0) ? items.count - 1 : selectedIdx - 1
            case .down: selectedIdx = (selectedIdx == items.count - 1) ? 0 : selectedIdx + 1
            case .number(let num):
                if num >= 1 && num <= items.count {
                    selectedIdx = num - 1
                    message = handleModifyChoice(selectedIdx, database: database)
                    if message == "__RETURNED__" { return }
                }
            case .enter:
                message = handleModifyChoice(selectedIdx, database: database)
                if message == "__RETURNED__" { return }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            default: break
            }
        }
    }

    // Returns a status message to display, or the sentinel "__RETURNED__"
    // if this choice already navigated away (so the caller knows to stop
    // its own loop rather than keep redrawing a screen it's leaving).
    private func handleModifyChoice(_ idx: Int, database: BaseDatabase) -> String {
        switch idx {
        case 0:
            guard let url = exportCSVTemplate(database) else { return "Export failed." }
            return "Template exported to \(url.lastPathComponent)."
        case 1:
            let safeName = database.name.replacingOccurrences(of: " ", with: "_")
            let expectedFilename = "\(safeName)_template.csv"
            let url = resolveAppDataDirectory().appendingPathComponent(expectedFilename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return "'\(expectedFilename)' not found in the app data directory."
            }
            let count = importCSV(database, from: url)
            return count > 0 ? "Imported \(count) record(s)." : "No records imported — check the file's headers match your field names."
        case 2:
            keyboard.disableRawMode()
            print("\n Delete ALL records in \(database.name)? This cannot be undone. (y/n): ", terminator: "")
            let confirmed = (readLine() ?? "").lowercased() == "y"
            keyboard.enableRawMode()
            guard confirmed else { return "Cancelled." }
            deleteAllRecords(database)
            return "All records deleted."
        case 3:
            keyboard.disableRawMode()
            navigate(to: .manageFields(database: database))
            return "__RETURNED__"
        case 4:
            keyboard.disableRawMode()
            goBack()
            return "__RETURNED__"
        default:
            return ""
        }
    }

    // MARK: - Manage Fields (reorder, rename, add, delete)
    // Field order here drives everything else -- card layout, table
    // columns, and which field acts as the primary display value in every
    // list screen -- so reordering is a first-class action, not an
    // afterthought. Renaming is the one operation that needs real care:
    // records store their values keyed BY field name, so renaming without
    // migrating every record's value to the new key wouldn't delete that
    // data, it would just make it silently invisible, still sitting there
    // under a key nothing displays anymore.
    func showManageFieldsScreen(database: BaseDatabase) {
        keyboard.enableRawMode()
        var fields = database.fields
        var selectedIdx = 0
        var message: String? = nil

        func persist() {
            var databases = loadDatabases()
            if let idx = databases.firstIndex(where: { $0.id == database.id }) {
                databases[idx].fields = fields
                saveDatabases(databases)
            }
        }

        while true {
            if selectedIdx >= fields.count { selectedIdx = max(0, fields.count - 1) }
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            let title = ">>> swiftBASE MANAGE FIELDS: \(database.name.uppercased()) <<<"
            let pad = max(0, (118 - title.count) / 2)
            print(String(repeating: " ", count: pad) + title)
            print(" Use Arrow Keys or type number selection")
            print("")

            for (idx, field) in fields.enumerated() {
                let isSelected = (idx == selectedIdx)
                let content: String
                if field.isBlankLine {
                    content = "[\(idx + 1)]. (blank line)"
                } else {
                    let hiddenTag = field.hiddenFromCard ? "  [hidden from card]" : ""
                    content = "[\(idx + 1)]. \(field.name)\(hiddenTag)"
                }
                if isSelected {
                    let full = " -> " + content
                    let padded = full.padding(toLength: 118, withPad: " ", startingAt: 0)
                    print("\u{001B}[7m\u{001B}[1m\(padded)\u{001B}[0m")
                } else {
                    print("    " + content)
                }
            }
            if let msg = message {
                print("")
                print(" \u{001B}[1;32m\(msg)\u{001B}[0m")
            }
            print("")
            printStandardFooter(keys: "Up/Down: select  -/+: reorder  [R]ename  [A]dd  [B]lank Line  [H]ide Toggle  [D]elete  ESC: Done")

            switch keyboard.readKey() {
            case .up:
                if !fields.isEmpty { selectedIdx = (selectedIdx == 0) ? fields.count - 1 : selectedIdx - 1 }
                message = nil
            case .down:
                if !fields.isEmpty { selectedIdx = (selectedIdx == fields.count - 1) ? 0 : selectedIdx + 1 }
                message = nil
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .other(let ch):
                message = nil
                if ch == "+" {
                    if selectedIdx > 0 {
                        fields.swapAt(selectedIdx, selectedIdx - 1)
                        selectedIdx -= 1
                        persist()
                    }
                } else if ch == "-" {
                    if selectedIdx < fields.count - 1 {
                        fields.swapAt(selectedIdx, selectedIdx + 1)
                        selectedIdx += 1
                        persist()
                    }
                } else {
                    let lower = Character(ch.lowercased())
                    if lower == "a" {
                        keyboard.disableRawMode()
                        print("\n New field name: ", terminator: "")
                        if let name = readLine(), !name.isEmpty {
                            if fields.contains(where: { $0.name == name }) {
                                message = "'\(name)' already exists."
                            } else {
                                fields.append(BaseField(name: name))
                                persist()
                                message = "Added '\(name)'."
                            }
                        }
                        keyboard.enableRawMode()
                    } else if lower == "b" {
                        // A dedicated action rather than an empty name typed
                        // into the regular Add prompt -- blank input there
                        // already means "I'm done adding fields," so reusing
                        // it here would collide with that existing meaning.
                        fields.insert(BaseField(name: ""), at: min(selectedIdx + 1, fields.count))
                        selectedIdx = min(selectedIdx + 1, fields.count - 1)
                        persist()
                        message = "Blank line inserted."
                    } else if lower == "h" && !fields.isEmpty && !fields[selectedIdx].isBlankLine {
                        fields[selectedIdx].hiddenFromCard.toggle()
                        persist()
                        message = fields[selectedIdx].hiddenFromCard
                            ? "'\(fields[selectedIdx].name)' hidden from the card view."
                            : "'\(fields[selectedIdx].name)' now shows on the card view."
                    } else if lower == "r" && !fields.isEmpty && !fields[selectedIdx].isBlankLine {
                        keyboard.disableRawMode()
                        let oldName = fields[selectedIdx].name
                        print("\n Rename '\(oldName)' to: ", terminator: "")
                        if let newName = readLine(), !newName.isEmpty, newName != oldName {
                            if fields.contains(where: { $0.name == newName }) {
                                message = "'\(newName)' already exists."
                            } else {
                                fields[selectedIdx].name = newName
                                // Migrate every record's value from the old
                                // key to the new one -- without this, the
                                // data doesn't get deleted, it just becomes
                                // permanently invisible under a key nothing
                                // displays anymore.
                                var databases = loadDatabases()
                                if let dbIdx = databases.firstIndex(where: { $0.id == database.id }) {
                                    databases[dbIdx].fields = fields
                                    for i in databases[dbIdx].records.indices {
                                        if let val = databases[dbIdx].records[i].values.removeValue(forKey: oldName) {
                                            databases[dbIdx].records[i].values[newName] = val
                                        }
                                    }
                                    saveDatabases(databases)
                                }
                                message = "Renamed '\(oldName)' to '\(newName)'."
                            }
                        }
                        keyboard.enableRawMode()
                    } else if lower == "d" && !fields.isEmpty {
                        let isBlank = fields[selectedIdx].isBlankLine
                        guard isBlank || fields.filter({ !$0.isBlankLine }).count > 1 else {
                            message = "A database needs at least one field."
                            continue
                        }
                        keyboard.disableRawMode()
                        let fieldToDelete = fields[selectedIdx]
                        let promptLabel = isBlank ? "this blank line" : "field '\(fieldToDelete.name)'"
                        print("\n Delete \(promptLabel)? \(isBlank ? "" : "This removes it from every record too. ")(y/n): ", terminator: "")
                        let confirmed = (readLine() ?? "").lowercased() == "y"
                        keyboard.enableRawMode()
                        if confirmed {
                            fields.remove(at: selectedIdx)
                            var databases = loadDatabases()
                            if let dbIdx = databases.firstIndex(where: { $0.id == database.id }) {
                                databases[dbIdx].fields = fields
                                if !isBlank {
                                    for i in databases[dbIdx].records.indices {
                                        databases[dbIdx].records[i].values.removeValue(forKey: fieldToDelete.name)
                                    }
                                }
                                saveDatabases(databases)
                            }
                            message = isBlank ? "Blank line deleted." : "Deleted '\(fieldToDelete.name)'."
                        } else {
                            message = "Cancelled."
                        }
                    } else if let target = navMapLookup()[lower] {
                        keyboard.disableRawMode()
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                        return
                    } else if lower == "l" {
                        keyboard.disableRawMode()
                        returnToLauncher()
                        return
                    }
                }
            default: break
            }
        }
    }

    // MARK: - Search (prompt-first, matching swiftCONTACTS' own showSearchScreen)
    func showSearchScreen(database: BaseDatabase) {
        printStandardHeader()
        let title = ">>> swiftBASE SEARCH <<<"
        let pad = max(0, (118 - title.count) / 2)
        print(String(repeating: " ", count: pad) + title)
        print(String(repeating: "─", count: 118))
        print(" Enter search phrase: ", terminator: "")
        guard let query = readLine(), !query.isEmpty else { goBack(); return }

        let results = database.records.filter { record in
            record.values.values.contains { $0.lowercased().contains(query.lowercased()) }
        }
        goBack()

        if results.isEmpty {
            print("\n No records matched '\(query)'.")
            print(" Press Enter to return...")
            _ = readLine()
        } else {
            navigate(to: .selectResult(database: database, results: results, title: "SEARCH RESULTS FOR '\(query.uppercased())'"))
        }
    }

    func showResultsScreen(database: BaseDatabase, results: [BaseRecord], title: String) {
        guard let displayField = database.fields.first(where: { !$0.isBlankLine })?.name else { goBack(); return }
        var localIdx = 0
        keyboard.enableRawMode()

        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            let pad = max(0, (118 - title.count) / 2)
            print(String(repeating: " ", count: pad) + title)
            print(" (Press ESC to go back)\n")

            for (idx, record) in results.enumerated() {
                let isSelected = (idx == localIdx)
                let display = record.values[displayField] ?? "(untitled)"
                let content = "[\(idx + 1)]. \(display)"
                if isSelected {
                    let full = " -> " + content
                    let padded = full.padding(toLength: 118, withPad: " ", startingAt: 0)
                    print("\u{001B}[7m\u{001B}[1m\(padded)\u{001B}[0m")
                } else {
                    print("    " + content)
                }
            }
            print(String(repeating: "─", count: 118))
            printStandardFooter(keys: "ENTER/1-9: View | ESC: Back")
            printNavFooter()

            switch keyboard.readKey() {
            case .up: if !results.isEmpty { localIdx = (localIdx == 0) ? results.count - 1 : localIdx - 1 }
            case .down: if !results.isEmpty { localIdx = (localIdx == results.count - 1) ? 0 : localIdx + 1 }
            case .number(let num):
                if !results.isEmpty && num >= 1 && num <= results.count {
                    keyboard.disableRawMode()
                    navigate(to: .viewRecord(database: database, record: results[num - 1]))
                    return
                }
            case .enter:
                if !results.isEmpty {
                    keyboard.disableRawMode()
                    navigate(to: .viewRecord(database: database, record: results[localIdx]))
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .other: break
            }
        }
    }

    // MARK: - Card View
    func showViewRecordScreen(database: BaseDatabase, record: BaseRecord) {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        let inner = 118
        print("╭" + String(repeating: "─", count: inner) + "╮")
        for field in database.fields where !field.hiddenFromCard {
            if field.isBlankLine {
                print("│\(String(repeating: " ", count: inner))│")
                continue
            }
            let value = record.values[field.name] ?? ""
            let label = field.name.padding(toLength: 20, withPad: " ", startingAt: 0)
            let line = "  \(label)\(value)"
            print("│\(line)\(String(repeating: " ", count: max(0, inner - line.count)))│")
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")
        print("")
        printStandardFooter(keys: "[E] Edit  |  [D] Delete  |  ESC: Back")
        printNavFooter()

        keyboard.enableRawMode()
        let key = keyboard.readKey()
        keyboard.disableRawMode()
        switch key {
        case .other(let ch) where ch.lowercased() == "e":
            navigate(to: .editRecord(database: database, record: record))
        case .other(let ch) where ch.lowercased() == "d":
            print("\n Delete this record? (y/n): ", terminator: "")
            if let confirm = readLine(), confirm.lowercased() == "y" {
                var databases = loadDatabases()
                if let dbIdx = databases.firstIndex(where: { $0.id == database.id }) {
                    databases[dbIdx].records.removeAll { $0.id == record.id }
                    saveDatabases(databases)
                }
            }
            goBack()
        case .other(let ch) where navMapLookup()[Character(ch.lowercased())] != nil:
            navigateToApp(navMapLookup()[Character(ch.lowercased())]!, args: [machineName, uptime, cpuUsage, memUsage])
        case .other(let ch) where ch.lowercased() == "l":
            returnToLauncher()
        default:
            goBack()
        }
    }

    // MARK: - Add Record
    func showAddRecordScreen(database: BaseDatabase) {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print(" ADD RECORD to \(database.name)\n")
        var values: [String: String] = [:]
        for field in database.fields where !field.isBlankLine {
            print(" \(field.name): ", terminator: "")
            values[field.name] = readLine() ?? ""
        }
        var databases = loadDatabases()
        if let dbIdx = databases.firstIndex(where: { $0.id == database.id }) {
            databases[dbIdx].records.append(BaseRecord(values: values))
            saveDatabases(databases)
            print("\n\u{001B}[1;32mRecord added.\u{001B}[0m Press Enter.")
        } else {
            print("\n\u{001B}[1;31mDatabase not found — record not saved.\u{001B}[0m Press Enter.")
        }
        _ = readLine()
        goBack()
    }

    // MARK: - Edit Record
    // Pre-fills each field's current value, matching the suite-wide edit
    // convention (e.g. swiftCALENDAR's edit flow) -- blank input keeps the
    // existing value rather than clearing it.
    func showEditRecordScreen(database: BaseDatabase, record: BaseRecord) {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print(" EDIT RECORD — press Enter on any field to keep its current value.\n")
        var newValues = record.values
        for field in database.fields where !field.isBlankLine {
            let current = record.values[field.name] ?? ""
            print(" \(field.name) [\(current)]: ", terminator: "")
            let input = readLine() ?? ""
            if !input.isEmpty { newValues[field.name] = input }
        }
        var databases = loadDatabases()
        if let dbIdx = databases.firstIndex(where: { $0.id == database.id }),
           let recIdx = databases[dbIdx].records.firstIndex(where: { $0.id == record.id }) {
            databases[dbIdx].records[recIdx].values = newValues
            saveDatabases(databases)
            print("\n\u{001B}[1;32mRecord updated.\u{001B}[0m Press Enter.")
        } else {
            print("\n\u{001B}[1;31mRecord not found — nothing saved.\u{001B}[0m Press Enter.")
        }
        _ = readLine()
        goBack()
        goBack()   // back past the (now-stale) view screen straight to the workspace
    }
}

// MARK: - Entry Point
let app = BaseApp()
app.run()