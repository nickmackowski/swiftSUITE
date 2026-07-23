import Foundation
import CryptoKit

// MARK: - Terminal Setup

var originalTermios = termios()
var isTerminalInitialized = false

func restoreTerminalSettings() {
    guard isTerminalInitialized else { return }
    var term = originalTermios
    term.c_lflag |= tcflag_t(ECHO) | tcflag_t(ICANON)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
}

func configureRawMode() {
    if !isTerminalInitialized {
        tcgetattr(STDIN_FILENO, &originalTermios)
        atexit(restoreTerminalSettings)
        isTerminalInitialized = true
    }
    var raw = originalTermios
    raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

// MARK: - Debug Logger

class CoreDebugLogger {
    static let logURL: URL = {
        let execPath = CommandLine.arguments[0]
        return URL(fileURLWithPath: execPath).deletingLastPathComponent()
            .appendingPathComponent("swiftcore_debug.log")
    }()

    static func log(_ message: String, category: String = "CORE") {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            try? data.write(to: logURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
    }
}

// MARK: - Credential Management

func getCredentialFile() -> URL {
    let execPath = CommandLine.arguments[0]
    return URL(fileURLWithPath: execPath).deletingLastPathComponent()
        .appendingPathComponent(".core_credentials")
}

func hashPassword(_ password: String, salt: Data) -> String {
    var hasher = SHA256()
    hasher.update(data: salt)
    hasher.update(data: Data(password.utf8))
    return Data(hasher.finalize()).base64EncodedString()
}

func credentialsExist() -> Bool {
    FileManager.default.fileExists(atPath: getCredentialFile().path)
}

/// Derives a 32-byte session key from the user's password and stored salt.
/// Used to give other apps in the suite a cryptographic proof of authentication
/// without requiring them to prompt for a separate password.
func deriveSessionKey(password: String, salt: Data) -> Data {
    var hasher = SHA256()
    hasher.update(data: salt)
    hasher.update(data: Data(password.utf8))
    hasher.update(data: Data("swiftCORE-unified-auth-v2.5".utf8))
    return Data(hasher.finalize())
}

func setupFirstTimeCredentials(snapshot: SystemSnapshot) {
    print("\u{001B}[2J\u{001B}[H", terminator: "")
    printHeader(snapshot: snapshot, username: "UNKNOWN")
    let inner = 118
    print("╭" + String(repeating: "─", count: inner) + "╮")
    func centeredLine(_ text: String, colored: String? = nil) {
        let p = max(0, (inner - text.count) / 2)
        print("│" + String(repeating: " ", count: p) + (colored ?? text) + String(repeating: " ", count: inner - p - text.count) + "│")
    }
    centeredLine("")
    centeredLine(swiftCoreBannerPlain(), colored: swiftCoreBannerColored())
    centeredLine("")
    centeredLine("─── First Launch Setup ───")
    centeredLine("")
    centeredLine("No credentials found. Let's create your login.")
    centeredLine("There is no recovery if you forget your password.")
    centeredLine("")
    print("╰" + String(repeating: "─", count: inner) + "╯")
    printNavFooter(currentApp: nil)

    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    term.c_lflag |= tcflag_t(ECHO) | tcflag_t(ICANON)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)

    print("\n Username: ", terminator: "")
    guard let username = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
        print("\n Username cannot be empty. Exiting."); exit(1)
    }

    while true {
        term.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)

        print(" Password (min 8 characters): ", terminator: "")
        guard let pw1 = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !pw1.isEmpty else { continue }
        if pw1.count < 8 { print("\n Use at least 8 characters.\n"); continue }

        print("\n Confirm password: ", terminator: "")
        guard let pw2 = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

        term.c_lflag |= tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)

        if pw1 != pw2 { print("\n Passwords didn't match — try again.\n"); continue }

        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let hash = hashPassword(pw1, salt: salt)
        let credLine = "\(username)\t\(salt.base64EncodedString())\t\(hash)"

        do {
            try credLine.write(to: getCredentialFile(), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: getCredentialFile().path)
            CoreDebugLogger.log("First-time credentials created (user redacted)", category: "AUTH")
            print("\n\n \u{001B}[1;32mCredentials saved. Welcome to swiftCORE.\u{001B}[0m\n")
            Thread.sleep(forTimeInterval: 0.8)
        } catch {
            print("\n Failed to save credentials: \(error). Exiting."); exit(1)
        }
        break
    }
}

func verifyCredentials(username: String, password: String) -> Bool {
    guard let content = try? String(contentsOf: getCredentialFile(), encoding: .utf8) else { return false }
    let parts = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
    guard parts.count == 3, let salt = Data(base64Encoded: parts[1]) else { return false }
    return username == parts[0] && hashPassword(password, salt: salt) == parts[2]
}

// MARK: - Session Management

func getSessionFile() -> URL {
    let execPath = CommandLine.arguments[0]
    return URL(fileURLWithPath: execPath).deletingLastPathComponent()
        .appendingPathComponent(".core_session")
}

func readSession() -> (isValid: Bool, lastLogin: Date?, username: String?) {
    guard let content = try? String(contentsOf: getSessionFile(), encoding: .utf8) else { return (false, nil, nil) }
    var expires: Double? = nil
    var lastLogin: Double? = nil
    var username: String? = nil
    for line in content.components(separatedBy: "\n") {
        let parts = line.components(separatedBy: ":")
        if parts.count == 2 {
            if parts[0] == "expires"   { expires   = Double(parts[1]) }
            if parts[0] == "lastlogin" { lastLogin = Double(parts[1]) }
            if parts[0] == "user"      { username  = parts[1] }
        }
    }
    let valid = expires.map { Date().timeIntervalSince1970 < $0 } ?? false
    return (valid, lastLogin.map { Date(timeIntervalSince1970: $0) }, username)
}

func updateSessionTimestamp(recordLogin: Bool = false, username: String? = nil, sessionKey: Data? = nil) {
    let sessionFile = getSessionFile()
    let expiryTime = Date().timeIntervalSince1970 + 1800
    var lines = ["expires:\(expiryTime)"]
    if recordLogin, let user = username {
        lines.append("lastlogin:\(Date().timeIntervalSince1970)")
        lines.append("user:\(user)")
    } else if let existing = try? String(contentsOf: sessionFile, encoding: .utf8) {
        for line in existing.components(separatedBy: "\n") where line.hasPrefix("lastlogin:") || line.hasPrefix("user:") || line.hasPrefix("skey:") {
            lines.append(line)
        }
    }
    if let skey = sessionKey {
        // Replace or add skey
        lines.removeAll { $0.hasPrefix("skey:") }
        lines.append("skey:\(skey.base64EncodedString())")
    }
    let content = lines.joined(separator: "\n")
    try? content.write(to: sessionFile, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFile.path)
}

func invalidateSession() {
    try? FileManager.default.removeItem(at: getSessionFile())
    CoreDebugLogger.log("Session invalidated by user logout", category: "AUTH")
}

// MARK: - System Snapshot

struct SystemSnapshot {
    let machineName: String
    let uptime: String
    let cpuUsage: String
    let memUsage: String

    static func capture() -> SystemSnapshot {
        var buffer = [CChar](repeating: 0, count: 256)
        let hostName = gethostname(&buffer, buffer.count) == 0 ?
            (String(cString: buffer).components(separatedBy: ".").first ?? "macOS") : "macOS"

        var mib = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var uptimeStr = "Unknown"
        if sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 {
            let secs = time(nil) - bootTime.tv_sec
            let days = secs / 86400; let hours = (secs % 86400) / 3600
            uptimeStr = days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
        }

        func runCmd(_ args: [String]) -> String {
            let p = Process(); let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args; p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let top = runCmd(["top", "-l", "1", "-n", "0"])
        var cpuStr = "0%"
        if let line = top.components(separatedBy: "\n").first(where: { $0.contains("CPU usage:") }) {
            let parts = line.components(separatedBy: CharacterSet(charactersIn: " %"))
            if let idx = parts.firstIndex(of: "usage:"), idx + 1 < parts.count { cpuStr = parts[idx+1] + "%" }
        }
        var memStr = "0G"
        if let line = top.components(separatedBy: "\n").first(where: { $0.contains("PhysMem:") }) {
            let tokens = line.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if let idx = tokens.firstIndex(where: { $0.contains("PhysMem:") }), idx + 1 < tokens.count {
                memStr = tokens[idx+1].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ",", with: "")
            }
        }
        return SystemSnapshot(machineName: hostName, uptime: uptimeStr, cpuUsage: cpuStr, memUsage: memStr)
    }
}

// MARK: - 3-Box UI Layout

let totalWidth = 120
let innerWidth  = 118  // totalWidth - 2 for │ borders

/// Top box — telemetry header, identical to all other apps in the suite.
func printHeader(snapshot: SystemSnapshot, username: String) {
    let now = Date()
    let dateFmt = DateFormatter(); dateFmt.dateFormat = "MM-dd-yy"
    let timeFmt = DateFormatter(); timeFmt.dateFormat = "hh:mm:ss a"
    let dateStr = dateFmt.string(from: now)
    let timeStr = timeFmt.string(from: now).uppercased()

    let titleText = "swiftCORE v2.5.07.11c"  // plain for layout; colored below
    let sidePad = (innerWidth - titleText.count) / 2
    var titleChars = Array(repeating: " ", count: innerWidth)
    for (i, ch) in dateStr.enumerated() where i < innerWidth { titleChars[i] = String(ch) }
    for (i, ch) in titleText.enumerated() { titleChars[sidePad + i] = String(ch) }
    // Color "swift" to match the login banner (swiftCoreBannerColored()) — per-letter accents.
    // CORE and the rest of the line stay exactly as they were: plain, uncolored.
    titleChars[sidePad + 0] = "\u{001B}[1;38;5;221ms\u{001B}[0m"
    titleChars[sidePad + 1] = "\u{001B}[1;38;5;208mw\u{001B}[0m"
    titleChars[sidePad + 2] = "\u{001B}[1;38;5;141mi\u{001B}[0m"
    titleChars[sidePad + 3] = "\u{001B}[1;38;5;80mf\u{001B}[0m"
    titleChars[sidePad + 4] = "\u{001B}[1;38;5;69mt\u{001B}[0m"
    // Color the trailing 'c' orange without affecting layout positions
    titleChars[sidePad + titleText.count - 1] = "\u{001B}[38;5;208mc\u{001B}[0m"
    let timeStart = innerWidth - timeStr.count
    for (i, ch) in timeStr.enumerated() { titleChars[timeStart + i] = String(ch) }

    let seg1Raw = "User: \(username)"
    let seg1Col = "User: \u{001B}[1;33m\(username)\u{001B}[0m"
    let seg2 = "Connected: [\(snapshot.machineName)]"
    let seg3 = "Host Uptime: \(snapshot.uptime)"
    let seg4 = "CPU: \(snapshot.cpuUsage)"
    let seg5 = "Mem: \(snapshot.memUsage)"
    let remaining = max(4, innerWidth - seg1Raw.count - seg2.count - seg3.count - seg4.count - seg5.count)
    let base = String(repeating: " ", count: remaining / 4)
    let extra = remaining % 4
    let telRaw = "\(seg1Raw)\(base + (extra > 0 ? " " : ""))\(seg2)\(base + (extra > 1 ? " " : ""))\(seg3)\(base + (extra > 2 ? " " : ""))\(seg4)\(base)\(seg5)"
    let telCol = "\(seg1Col)\(base + (extra > 0 ? " " : ""))\(seg2)\(base + (extra > 1 ? " " : ""))\(seg3)\(base + (extra > 2 ? " " : ""))\(seg4)\(base)\(seg5)"
    let telPad = max(0, innerWidth - telRaw.count)

    print("╭" + String(repeating: "─", count: innerWidth) + "╮")
    print("│" + titleChars.joined() + "│")
    print("│" + telCol + String(repeating: " ", count: telPad) + "│")
    print("╰" + String(repeating: "─", count: innerWidth) + "╯")
}

/// Plain (uncolored) banner text, used for width/centering math — ANSI escape codes count
/// toward String.count but aren't visible in the terminal, so padding must be computed against
/// this version, never against swiftCoreBannerColored().
func swiftCoreBannerPlain() -> String {
    "s w i f t C O R E"
}

/// "swift" — each letter gets its own accent color (gold/orange/purple/teal/blue); "CORE" is
/// bold white. Shared by the login screen, the post-login app-select screen, and the
/// first-launch setup screen so all three stay in sync if the palette changes later.
func swiftCoreBannerColored() -> String {
    let goldS   = "\u{001B}[1;38;5;221ms\u{001B}[0m"
    let orangeW = "\u{001B}[1;38;5;208mw\u{001B}[0m"
    let purpleI = "\u{001B}[1;38;5;141mi\u{001B}[0m"
    let tealF   = "\u{001B}[1;38;5;80mf\u{001B}[0m"
    let blueT   = "\u{001B}[1;38;5;69mt\u{001B}[0m"
    let corePart = "\u{001B}[97mC O R E\u{001B}[0m"
    return goldS + " " + orangeW + " " + purpleI + " " + tealF + " " + blueT + " " + corePart
}

/// Middle box — swiftCORE title + login fields (pre-auth) or app content (post-auth).
/// On the login screen, showLoginPrompt is true. After launch, each app draws this itself.
func printLoginBox(lastLoginStr: String? = nil, message: String? = nil, messageIsError: Bool = false) {
    print("╭" + String(repeating: "─", count: innerWidth) + "╮")

    // Blank line above title
    print("│" + String(repeating: " ", count: innerWidth) + "│")

    // s w i f t C O R E — swift in per-letter accent colors, CORE in bold white, centered
    let title = swiftCoreBannerPlain()
    let titlePad = (innerWidth - title.count) / 2
    print("│" + String(repeating: " ", count: titlePad) + swiftCoreBannerColored() + String(repeating: " ", count: innerWidth - titlePad - title.count) + "│")

    // Blank line below title
    print("│" + String(repeating: " ", count: innerWidth) + "│")

    // Separator
    print("├" + String(repeating: "─", count: innerWidth) + "┤")

    // login: and Password: on one line
    // login: starts at col 35, Password: starts at col 68 (verified in Python above)
    let loginLabel = "login: "   // 7 chars — trailing space included so cursor lands cleanly after the colon
    let passLabel  = "Password: " // 10 chars
    let loginStart = 35
    let passStart  = 68
    var fieldLine  = Array(repeating: " ", count: innerWidth)
    for (i, c) in loginLabel.enumerated() { fieldLine[loginStart + i] = String(c) }
    for (i, c) in passLabel.enumerated()  { fieldLine[passStart  + i] = String(c) }
    print("│" + fieldLine.joined() + "│")

    // Blank line
    print("│" + String(repeating: " ", count: innerWidth) + "│")

    // Separator before status area
    print("├" + String(repeating: "─", count: innerWidth) + "┤")

    // Status / last-login line
    if let msg = message {
        let color = messageIsError ? "\u{001B}[1;31m" : "\u{001B}[1;32m"
        let visLen = msg.count
        let mpad = max(0, (innerWidth - visLen) / 2)
        print("│" + String(repeating: " ", count: mpad) + color + msg + "\u{001B}[0m" + String(repeating: " ", count: innerWidth - mpad - visLen) + "│")
    } else if let lastLogin = lastLoginStr {
        let text = "Last login: \(lastLogin)"
        let lpad = max(0, (innerWidth - text.count) / 2)
        let dimmed = "\u{001B}[2m\(text)\u{001B}[0m"
        print("│" + String(repeating: " ", count: lpad) + dimmed + String(repeating: " ", count: innerWidth - lpad - text.count) + "│")
    } else {
        print("│" + String(repeating: " ", count: innerWidth) + "│")
    }

    print("╰" + String(repeating: "─", count: innerWidth) + "╯")
}

/// Bottom box — nav footer. currentApp is the binary name of the active app (nil on login
/// screen). The matching app key shows in green; all others are dimmed.
func printNavFooter(currentApp: String?) {
    // Map: display label → binary folder name
    let navItems: [(key: String, label: String, app: String)] = [
        ("T", "Contacts",  "swiftCONTACTS"),
        ("C", "Calendar",  "swiftCALENDAR"),
        ("M", "Mail",      "swiftMAIL"),
        ("N", "Notes",     "swiftNOTES"),
        ("S", "Stocks",    "swiftSTOCKS"),
        ("V", "Vault",     "swiftVAULT"),
        ("L", "Logout",    "LOGOUT"),
    ]

    // Build the visible nav string first (plain, for length), then the colored version
    let plainParts = navItems.map { "[\($0.key)] \($0.label)" }
    let plainNav   = plainParts.joined(separator: "  ")
    let navPad     = max(0, (innerWidth - plainNav.count) / 2)

    var coloredNav = ""
    for (idx, item) in navItems.enumerated() {
        let isActive = item.app == currentApp
        let isLogout = item.app == "LOGOUT"
        let part = "[\(item.key)] \(item.label)"
        if isLogout {
            coloredNav += "\u{001B}[1;31m\(part)\u{001B}[0m"
        } else if isActive {
            coloredNav += "\u{001B}[1;32m\(part)\u{001B}[0m"
        } else {
            coloredNav += "\u{001B}[2m\(part)\u{001B}[0m"
        }
        if idx < navItems.count - 1 { coloredNav += "  " }
    }

    print("╭" + String(repeating: "─", count: innerWidth) + "╮")
    print("│" + String(repeating: " ", count: navPad) + coloredNav + String(repeating: " ", count: innerWidth - navPad - plainNav.count) + "│")
    print("╰" + String(repeating: "─", count: innerWidth) + "╯")
}

// MARK: - App Launcher

func launchApp(named appName: String, snapshot: SystemSnapshot) {
    let currentExecutionPath = CommandLine.arguments[0]
    let currentDirURL = URL(fileURLWithPath: currentExecutionPath).deletingLastPathComponent()
    let targetAppFolderURL = currentDirURL.deletingLastPathComponent().appendingPathComponent(appName)
    let absoluteBinaryPath = targetAppFolderURL.appendingPathComponent(appName).path

    guard FileManager.default.fileExists(atPath: absoluteBinaryPath) else {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        printHeader(snapshot: snapshot, username: readSession().username ?? "UNKNOWN")
        printLoginBox(message: "Error: binary not found for \(appName)", messageIsError: true)
        printNavFooter(currentApp: nil)
        print("\n Press any key to continue...")
        _ = getchar()
        return
    }

    restoreTerminalSettings()
    if chdir(targetAppFolderURL.path) != 0 { print("Error: chdir failed"); exit(1) }

    let cPath    = absoluteBinaryPath.withCString { strdup($0) }
    let cMachine = snapshot.machineName.withCString { strdup($0) }
    let cUptime  = snapshot.uptime.withCString { strdup($0) }
    let cCpu     = snapshot.cpuUsage.withCString { strdup($0) }
    let cMem     = snapshot.memUsage.withCString { strdup($0) }
    let cArgs: [UnsafeMutablePointer<CChar>?] = [cPath, cMachine, cUptime, cCpu, cMem, nil]
    execv(absoluteBinaryPath, cArgs)
    print("Fatal Error: execv failed for \(appName)."); exit(1)
}

// MARK: - Login Gate

func runLoginGate(snapshot: SystemSnapshot) {
    if !credentialsExist() {
        setupFirstTimeCredentials(snapshot: snapshot)
    }

    // Session still valid — skip login entirely
    let (valid, lastLogin, _) = readSession()
    if valid {
        updateSessionTimestamp(recordLogin: false)
        CoreDebugLogger.log("Session resumed (user redacted)", category: "AUTH")
        return
    }

    // Draw the login screen and prompt
    var lastLoginStr: String? = nil
    if let ll = lastLogin {
        let fmt = DateFormatter(); fmt.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        lastLoginStr = fmt.string(from: ll).uppercased() + " on tty07"
    }

    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    term.c_lflag |= tcflag_t(ECHO) | tcflag_t(ICANON)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)

    var attempts = 0
    var errorMsg: String? = nil

    while attempts < 5 {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        printHeader(snapshot: snapshot, username: "UNKNOWN")
        printLoginBox(lastLoginStr: lastLoginStr, message: errorMsg, messageIsError: errorMsg != nil)
        printNavFooter(currentApp: nil)

        // Move cursor back up inside the middle box to the login/password field line.
        // printLoginBox = 10 lines, printNavFooter = 3 lines → cursor is at line 14.
        // The field line is line 6 → go up 8 lines, then position to col 44 (after "login: ").
        print("\u{001B}[8A\u{001B}[44G", terminator: "")
        fflush(stdout)

        guard let user = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty else { exit(0) }

        // Go back up 1 line (readLine() dropped cursor to line 7), position after "Password: " at col 80
        print("\u{001B}[1A\u{001B}[80G", terminator: "")
        term.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
        fflush(stdout)

        guard let pass = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { exit(0) }

        term.c_lflag |= tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)

        if verifyCredentials(username: user, password: pass) {
            // Derive session key from password + stored salt — gives other apps
            // cryptographic proof of auth without needing separate passwords
            let credContent = (try? String(contentsOf: getCredentialFile(), encoding: .utf8)) ?? ""
            let credParts = credContent.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
            let credSalt = credParts.count >= 2 ? Data(base64Encoded: credParts[1]) ?? Data() : Data()
            let skey = deriveSessionKey(password: pass, salt: credSalt)
            updateSessionTimestamp(recordLogin: true, username: user, sessionKey: skey)
            CoreDebugLogger.log("Successful login (user redacted)", category: "AUTH")

            // Show ACCESS GRANTED + last login on one line in the status area
            let (_, prevLogin, _) = readSession()
            var accessMsg = "ACCESS GRANTED"
            if let prevLogin = prevLogin {
                let fmt = DateFormatter()
                fmt.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
                accessMsg += "  ·  Last login: \(fmt.string(from: prevLogin).uppercased()) on tty07"
            }
            print("\u{001B}[2J\u{001B}[H", terminator: "")
            printHeader(snapshot: snapshot, username: user)
            printLoginBox(message: accessMsg, messageIsError: false)
            printNavFooter(currentApp: nil)
            Thread.sleep(forTimeInterval: 1.0)
            return
        }

        attempts += 1
        CoreDebugLogger.log("Failed login attempt \(attempts) (user redacted)", category: "AUTH")
        Thread.sleep(forTimeInterval: 0.5)
        errorMsg = "LOGIN INCORRECT  (\(attempts) of 5 attempts)"

        if attempts >= 5 {
            print("\u{001B}[2J\u{001B}[H", terminator: "")
            printHeader(snapshot: snapshot, username: "UNKNOWN")
            printLoginBox(message: "Maximum attempts exceeded — connection terminated", messageIsError: true)
            printNavFooter(currentApp: nil)
            Thread.sleep(forTimeInterval: 1.5)
            CoreDebugLogger.log("Locked out after 5 failed attempts", category: "AUTH")
            exit(1)
        }
    }
}

// MARK: - Backup Utility

func runBackupUtility(snapshot: SystemSnapshot) {
    restoreTerminalSettings()
    print("\u{001B}[2J\u{001B}[H", terminator: "")
    printHeader(snapshot: snapshot, username: readSession().username ?? "UNKNOWN")

    let currentDirURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let parentURL = currentDirURL.deletingLastPathComponent()
    let backupDirURL = parentURL.appendingPathComponent("swiftCORE Suite Backup")
    if !FileManager.default.fileExists(atPath: backupDirURL.path) {
        try? FileManager.default.createDirectory(at: backupDirURL, withIntermediateDirectories: true)
    }

    let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
    let archiveName = "swiftcore_backup_\(fmt.string(from: Date())).tar.gz"
    let destURL = backupDirURL.appendingPathComponent(archiveName)

    print("╭" + String(repeating: "─", count: innerWidth) + "╮")
    func boxLine(_ text: String) {
        let p = max(0, (innerWidth - text.count) / 2)
        print("│" + String(repeating: " ", count: p) + text + String(repeating: " ", count: innerWidth - p - text.count) + "│")
    }
    boxLine("")
    boxLine("swiftCORE Backup Engine")
    boxLine("")
    boxLine("Archiving entire suite...")
    boxLine(destURL.path)
    boxLine("")
    print("╰" + String(repeating: "─", count: innerWidth) + "╯")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-czf", destURL.path, "--exclude=*.tar.gz",
                         "--exclude=swiftCORE Suite Backup", "-C", parentURL.path, "."]
    do {
        try process.run(); process.waitUntilExit()
        if process.terminationStatus == 0 {
            print("\n \u{001B}[1;32mBackup complete: \(archiveName)\u{001B}[0m")
            CoreDebugLogger.log("Backup created: \(archiveName)", category: "BACKUP")
        } else {
            print("\n \u{001B}[1;31mBackup failed (exit \(process.terminationStatus))\u{001B}[0m")
        }
    } catch {
        print("\n \u{001B}[1;31mBackup error: \(error)\u{001B}[0m")
    }
    print("\n Press any key to return...")
    _ = getchar()
    configureRawMode()
}

// MARK: - Main

func main() {
    // Always chdir to the launcher's own folder so relative execv paths work correctly
    let launcherDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    if chdir(launcherDir.path) != 0 { print("Error: chdir failed"); exit(1) }

    let snapshot = SystemSnapshot.capture()
    runLoginGate(snapshot: snapshot)

    // App map: letter key → binary folder name
    let appMap: [Character: String] = [
        "c": "swiftCALENDAR",
        "n": "swiftNOTES",
        "s": "swiftSTOCKS",
        "m": "swiftMAIL",
        "v": "swiftVAULT",
        "t": "swiftCONTACTS",
    ]

    configureRawMode()

    // After login, show the nav screen and let the user pick an app
    while true {
        let (_, _, currentUser) = readSession()
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        printHeader(snapshot: snapshot, username: currentUser ?? "UNKNOWN")

        // Middle box — same colored title as the login screen (shared helper keeps them in sync)
        let title2 = swiftCoreBannerPlain()
        let title2Pad = (innerWidth - title2.count) / 2
        print("╭" + String(repeating: "─", count: innerWidth) + "╮")
        print("│" + String(repeating: " ", count: innerWidth) + "│")
        print("│" + String(repeating: " ", count: title2Pad) + swiftCoreBannerColored() + String(repeating: " ", count: innerWidth - title2Pad - title2.count) + "│")
        print("│" + String(repeating: " ", count: innerWidth) + "│")
        print("├" + String(repeating: "─", count: innerWidth) + "┤")
        let prompt = "Select an application from the menu below."
        let ppad = max(0, (innerWidth - prompt.count) / 2)
        print("│" + String(repeating: " ", count: ppad) + prompt + String(repeating: " ", count: innerWidth - ppad - prompt.count) + "│")
        print("╰" + String(repeating: "─", count: innerWidth) + "╯")
        printNavFooter(currentApp: nil)

        // Raw mode single-keypress
        var buf = [UInt8](repeating: 0, count: 3)
        let n = read(STDIN_FILENO, &buf, 3)
        guard n > 0 else { continue }

        let ch = Character(UnicodeScalar(buf[0]))
        let lower = Character(ch.lowercased())

        if lower == "l" {
            // Logout — invalidate session and exit to terminal
            restoreTerminalSettings()
            invalidateSession()
            print("\u{001B}[2J\u{001B}[H", terminator: "")
            print(" Session ended. Goodbye.")
            CoreDebugLogger.log("User logged out", category: "AUTH")
            exit(0)
        } else if lower == "b" {
            // [B] Backup — hidden utility key, not shown in nav
            restoreTerminalSettings()
            runBackupUtility(snapshot: snapshot)
            configureRawMode()
        } else if let appName = appMap[lower] {
            restoreTerminalSettings()
            launchApp(named: appName, snapshot: snapshot)
            // If launchApp returns (binary not found), re-enter raw mode and show menu again
            configureRawMode()
        }
        // Any other key: just redraw
    }
}

main()