// ═══════════════════════════════════════════════════════════════
// APP: swiftVIEW
// A passive, read-only glance companion — shows swiftNOTES' notes and
// swiftCALENDAR's events together in one list. Click an item to see its
// full details in a small popup; nothing here can be edited or deleted.
// Purely something that sits on the desktop for a quick look at what's
// going on, not a second way to manage your notes or calendar.
// File: Sources/swiftVIEW/main.swift
// ═══════════════════════════════════════════════════════════════

import Cocoa
import CryptoKit

// MARK: - Shared opacity (from swiftCT)
// swiftCT writes its currently-saved theme's opacity to a shared JSON file inside the
// swiftSUITE folder (not UserDefaults — each compiled app has its own separate UserDefaults
// domain, so that wouldn't be visible here). This is a read-only, minimal duplicate of that
// same struct/lookup — decoding only pulls out the one field this app cares about and
// silently ignores the rest, so it stays safe to read even as swiftCT's own config grows.
// This app never writes to this file, only reads it, so there's no risk of clobbering
// swiftCT's Syncthing/Tailscale settings that also live in it.
private struct SharedTerminalConfig: Codable {
    var terminalOpacity: Double?
}

private func locateSwiftSuiteRoot() -> URL? {
    var dir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()

    for _ in 0..<6 {   // generous ceiling — covers both .app-bundled and standalone invocation
        let candidate = dir.appendingPathComponent("swiftCORE/swiftCORE")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return dir
        }
        let parent = dir.deletingLastPathComponent()
        if parent == dir { break }   // hit filesystem root, stop
        dir = parent
    }
    return nil
}

let suiteRoot = locateSwiftSuiteRoot()

private func loadSharedTerminalOpacity() -> CGFloat {
    guard let root = suiteRoot else { return 1.0 }
    let url = root.appendingPathComponent("swiftCT").appendingPathComponent("swiftsuite-config.json")
    guard let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(SharedTerminalConfig.self, from: data),
          let opacity = config.terminalOpacity else {
        return 1.0
    }
    return CGFloat(opacity)
}

// MARK: - Session key (matches swiftNOTES exactly)
// Deliberately uses the appID "swiftNOTES", not "swiftVIEW" — the derived key has to be
// byte-for-byte identical to what the swiftNOTES CLI app itself derives, since this app is
// reading the exact same encrypted file, not a separate one of its own.
func readCoreSessionKey(appID: String) -> SymmetricKey? {
    guard let root = suiteRoot else { return nil }
    let sessionFile = root.appendingPathComponent("swiftcore").appendingPathComponent(".core_session")
    guard let content = try? String(contentsOf: sessionFile, encoding: .utf8) else { return nil }
    var expires: Double = 0
    var skeyBase64 = ""
    for line in content.components(separatedBy: "\n") {
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { continue }
        if parts[0] == "expires" { expires = Double(parts[1]) ?? 0 }
        if parts[0] == "skey"    { skeyBase64 = parts[1...].joined(separator: ":") }
    }
    guard Date().timeIntervalSince1970 < expires, !skeyBase64.isEmpty else { return nil }
    guard let skeyData = Data(base64Encoded: skeyBase64) else { return nil }
    var hasher = SHA256()
    hasher.update(data: skeyData)
    hasher.update(data: Data(appID.utf8))
    return SymmetricKey(data: Data(hasher.finalize()))
}

// MARK: - Notes data model (matches swiftNOTES' notes.json exactly — read-only here)

enum NotebookCryptoError: Error {
    case invalidCiphertext
    case decryptionFailed
}

enum NotebookCrypto {
    static let canaryPlaintext = "swiftNOTES-OK"

    static func decrypt(_ base64: String, key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw NotebookCryptoError.invalidCiphertext }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        guard let text = String(data: decryptedData, encoding: .utf8) else { throw NotebookCryptoError.invalidCiphertext }
        return text
    }
}

struct Note: Codable {
    var title: String = ""
    var encryptedBody: String = ""
    var tags: [String] = []
    var dateCreated: Date = Date()
    var dateModified: Date = Date()
    var isArchived: Bool = false
    var dueDate: Date? = nil
}

struct NotebookFile: Codable {
    var formatVersion: Int = 2
    var kdfSalt: String
    var kdfIterations: Int
    var canary: String
    var notes: [Note]
    var lastBackupTimestamp: String? = nil
}

// MARK: - Calendar data model (matches swiftCALENDAR's calendar.json exactly — no
// encryption involved at all here, unlike notes)

struct CalendarEvent: Codable {
    var id: UUID = UUID()
    var title: String = ""
    var location: String = ""
    var startTime: Date = Date()
    var endTime: Date = Date()
    var notes: String = ""
    var calendarName: String = ""
    var isAllDay: Bool = false
    var isLocal: Bool = false
    var decodedWeather: String? = nil
    var sunrise: String? = nil
    var sunset: String? = nil

    // Matches swiftCALENDAR's own CodingKeys exactly — isWeather/isBirthday/isDue are
    // computed at load time by swiftCALENDAR itself and never actually stored in
    // calendar.json, so they're deliberately left out here entirely (this app doesn't need
    // them for a read-only glance view). sunrise/sunset ARE genuinely persisted by
    // calendar_sync.py though, so unlike those, they're included here — optional, so
    // regular calendar events, local events, and birthdays (none of which ever have these
    // fields) simply decode them as nil rather than failing.
    enum CodingKeys: String, CodingKey {
        case id, title, location, startTime, endTime, notes, calendarName, isAllDay, isLocal, decodedWeather, sunrise, sunset
    }
}

// Same dark/light colors swiftSYSINFO itself uses — reused directly rather than inventing
// a separate palette.
let darkBackground = NSColor(calibratedRed: 0.098039, green: 0.113725, blue: 0.152941, alpha: 1.0)
let darkForeground = NSColor.white
let lightBackground = NSColor.white
let lightForeground = NSColor(calibratedRed: 89.0/255, green: 89.0/255, blue: 89.0/255, alpha: 1.0)

let greenbarColor = NSColor(calibratedRed: 0.0, green: 95.0/255.0, blue: 0.0, alpha: 1.0)
// Matches swiftCALENDAR's own weatherBlue (256-color 75) exactly — METAR/TAF entries always
// render this blue regardless of their account's own configured color, same as the terminal.
let weatherBlue = NSColor(calibratedRed: 95.0/255.0, green: 175.0/255.0, blue: 255.0/255.0, alpha: 1.0)
// Matches swiftCALENDAR's own localRed — local events get this color with top priority in
// its own agenda view, checked even before weather.
let localRed = NSColor(calibratedRed: 255.0/255.0, green: 85.0/255.0, blue: 85.0/255.0, alpha: 1.0)
// Matches swiftCALENDAR's own birthdayPurple (256-color 135).
let birthdayPurple = NSColor(calibratedRed: 175.0/255.0, green: 95.0/255.0, blue: 255.0/255.0, alpha: 1.0)
// Matches swiftCALENDAR's own dueYellow.
let dueYellow = NSColor(calibratedRed: 255.0/255.0, green: 214.0/255.0, blue: 51.0/255.0, alpha: 1.0)

// MARK: - Known airports (matches swiftCALENDAR's known_airports.json exactly)

struct AirportInfo: Codable {
    var display: String = ""
    var airportName: String = ""
    var iata: String = ""
    var lat: Double = 0
    var lon: Double = 0
}

func loadKnownAirports() -> [String: AirportInfo] {
    guard let root = suiteRoot else { return [:] }
    let url = root.appendingPathComponent("swiftCALENDAR").appendingPathComponent("known_airports.json")
    guard let data = try? Data(contentsOf: url),
          let airports = try? JSONDecoder().decode([String: AirportInfo].self, from: data) else {
        return [:]
    }
    return airports
}

// Loaded once — known_airports.json doesn't change during a run, matching swiftCALENDAR's
// own lazy-load-once approach.
let knownAirports = loadKnownAirports()

// MARK: - Raw METAR/TAF text parsing
// The observation/issuance timestamp and altimeter setting aren't separately stored fields
// anywhere — they're only ever present inside the raw text itself (event.title). Parsed
// fresh here since nothing on the Swift side already does this; calendar_sync.py's own
// decode_wx_code() parses the same groups, but on the Python side, for a different purpose
// (the human-readable summary), not exposing these specific values back to Swift.

// METAR/TAF day-time group: "DDHHMMZ" — day of month, hour, minute, UTC. No month/year is
// encoded (METAR doesn't need it, always assumed to be "recent"), so this combines the
// parsed day/hour/minute with the CURRENT month/year — correct for anything within the
// current month, which covers every real case here given METAR/TAF are always near-term.
func parseObservationTime(from rawText: String) -> Date? {
    guard let match = rawText.range(of: #"^\d{6}Z"#, options: .regularExpression) else { return nil }
    let group = rawText[match].dropLast()   // drop trailing "Z"
    guard group.count == 6,
          let day = Int(group.prefix(2)),
          let hour = Int(group.dropFirst(2).prefix(2)),
          let minute = Int(group.dropFirst(4).prefix(2)) else { return nil }

    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(identifier: "UTC")!
    let nowUTC = Date()

    // Builds a candidate date for the given year/month, returning nil if the day doesn't
    // actually exist in that month — detected by round-tripping the constructed date's
    // own components and checking they match what was actually asked for. Without this
    // check, Calendar.date(from:) silently overflows an invalid day (e.g. day 31 in a
    // 30-day month) into the wrong date instead of failing, which is exactly what caused
    // this bug: a reading genuinely from Aug 31 got silently reinterpreted as some
    // September date once the current month became September, and the corrupted result
    // then wrongly compared as "more recent" than genuine September readings.
    func buildDate(year: Int, month: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        guard let candidate = utcCalendar.date(from: comps) else { return nil }
        let actual = utcCalendar.dateComponents([.year, .month, .day], from: candidate)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return candidate
    }

    let nowComps = utcCalendar.dateComponents([.year, .month], from: nowUTC)
    guard let thisYear = nowComps.year, let thisMonth = nowComps.month else { return nil }

    // Try the current month first — covers the overwhelming majority of cases. Also
    // rejected if it lands more than 2 days in the future, the same safety margin
    // calendar_sync.py's own equivalent (build_utc_timestamp) already uses.
    if let candidate = buildDate(year: thisYear, month: thisMonth),
       candidate <= nowUTC.addingTimeInterval(2 * 24 * 3600) {
        return candidate
    }

    // Either the day doesn't exist in the current month, or the result was implausibly
    // far in the future — must belong to the previous month instead.
    let (prevYear, prevMonth) = thisMonth == 1 ? (thisYear - 1, 12) : (thisYear, thisMonth - 1)
    return buildDate(year: prevYear, month: prevMonth)
}

// Picks the reading with the latest REAL observation time (parsed from its own raw
// text), not the latest startTime — startTime is just an all-day date marker shared by
// every reading captured on the same calendar day now that metar_history.json keeps a
// full day's worth of readings per day instead of one, so it can't distinguish between
// them the way it used to when there was only ever a single entry per day.
func mostRecentReading(_ events: [CalendarEvent]) -> CalendarEvent? {
    events.max { a, b in
        let aTime = parseObservationTime(from: a.title) ?? a.startTime
        let bTime = parseObservationTime(from: b.title) ?? b.startTime
        return aTime < bTime
    }
}

// Altimeter group: "A" followed by 4 digits — inHg × 100 (e.g. "A2997" = 29.97 inHg).
func parseAltimeter(from rawText: String) -> Double? {
    guard let match = rawText.range(of: #"\bA\d{4}\b"#, options: .regularExpression) else { return nil }
    let digits = rawText[match].dropFirst()
    guard let raw = Int(digits) else { return nil }
    return Double(raw) / 100.0
}

// Temp/dewpoint group: "NN/NN" or "MNN/MNN" (M prefix means below zero Celsius) — the only
// bare-slash group in a standard METAR, so this is safe to match without colliding with
// wind, visibility, or cloud groups, none of which contain a "/".
func parseTempCelsius(from rawText: String) -> (temp: Int, dewpoint: Int)? {
    guard let match = rawText.range(of: #"\bM?\d{2}/M?\d{2}\b"#, options: .regularExpression) else { return nil }
    let parts = rawText[match].split(separator: "/")
    guard parts.count == 2 else { return nil }
    func value(_ s: Substring) -> Int? {
        if s.hasPrefix("M") { return Int(s.dropFirst()).map { -$0 } }
        return Int(s)
    }
    guard let temp = value(parts[0]), let dewpoint = value(parts[1]) else { return nil }
    return (temp, dewpoint)
}

// Magnus-Tetens approximation — relative humidity from temperature and dewpoint (both
// Celsius), accurate to within about 0.4% over METAR's realistic range. METAR only in
// practice: dewpoint here is an actual observation, not a forecast quantity the way TAF's
// temp/dewpoint-shaped field is.
func relativeHumidity(tempC: Double, dewpointC: Double) -> Int {
    func magnus(_ t: Double) -> Double {
        exp((17.625 * t) / (243.04 + t))
    }
    let rh = 100 * magnus(dewpointC) / magnus(tempC)
    return Int(rh.rounded())
}

// Visibility group: "NSM" (statute miles), optionally prefixed "P" (greater than, TAF's
// "P6SM") or "M" (less than). Doesn't attempt to handle fractional visibility ("1/2SM",
// low-visibility fog conditions) — a genuinely rare case for a quick-glance summary, and it
// just falls back gracefully to not showing a visibility figure rather than mis-parsing it.
func parseVisibility(from rawText: String) -> String? {
    guard let match = rawText.range(of: #"\b[PM]?\d{1,2}SM\b"#, options: .regularExpression) else { return nil }
    return String(rawText[match])
}

// A short, glanceable summary for the compact list row — visibility + Fahrenheit temp — 
// instead of cramming the full raw METAR/TAF text into a narrow row where it just truncates
// awkwardly no matter where the cut lands. The detail popup still shows everything in full.
func shortWeatherSummary(rawText: String, fahrenheitNotes: String) -> String {
    var parts: [String] = []
    if let vis = parseVisibility(from: rawText) { parts.append(vis) }
    if let firstTemp = fahrenheitNotes.split(separator: "/").first { parts.append(String(firstTemp)) }
    return parts.isEmpty ? rawText : parts.joined(separator: ", ")
}

// NSTextAttachment images need to be pre-tinted bitmaps — unlike NSImageView's
// contentTintColor, attachments embedded in attributed text don't auto-tint to match
// surrounding text color, so this renders the SF Symbol into a correctly-colored bitmap
// once, up front.
func tintedSymbolImage(systemName: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
    guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else { return nil }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let sized = base.withSymbolConfiguration(config) else { return nil }
    let tinted = NSImage(size: sized.size)
    tinted.lockFocus()
    color.set()
    let rect = NSRect(origin: .zero, size: sized.size)
    sized.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    rect.fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

// swiftNOTES prepends "[MM/dd/yy hh:mm a]" to a note's body both when it's first created and
// again every time text gets appended later — a single note can end up with several of these
// scattered through it, not just one at the top. Shown as raw bracketed text, that reads as
// sloppy/cluttered in a small popup; this replaces each occurrence with a small inline clock
// icon plus a cleaner time-only label instead.
func attributedBody(_ rawBody: String, font: NSFont, color: NSColor, iconSize: CGFloat) -> NSAttributedString {
    let pattern = #"\[\d{2}/\d{2}/\d{2} \d{2}:\d{2} (AM|PM)\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return NSAttributedString(string: rawBody, attributes: [.font: font, .foregroundColor: color])
    }

    let sourceFormatter = DateFormatter()
    sourceFormatter.dateFormat = "MM/dd/yy hh:mm a"
    let displayFormatter = DateFormatter()
    displayFormatter.dateFormat = "MMM d, h:mm a"

    let nsRange = NSRange(rawBody.startIndex..., in: rawBody)
    let matches = regex.matches(in: rawBody, range: nsRange)
    let clockIcon = tintedSymbolImage(systemName: "clock", color: color, pointSize: font.pointSize * 0.85)

    let result = NSMutableAttributedString()
    var cursor = rawBody.startIndex
    for match in matches {
        guard let range = Range(match.range, in: rawBody) else { continue }
        if cursor < range.lowerBound {
            result.append(NSAttributedString(string: String(rawBody[cursor..<range.lowerBound]), attributes: [.font: font, .foregroundColor: color]))
        }

        let bracketText = String(rawBody[range]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let timeLabel = sourceFormatter.date(from: bracketText).map { displayFormatter.string(from: $0) } ?? bracketText

        if let icon = clockIcon {
            let attachment = NSTextAttachment()
            attachment.image = icon
            let attachmentString = NSAttributedString(attachment: attachment)
            result.append(attachmentString)
            result.append(NSAttributedString(string: " \(timeLabel)", attributes: [.font: font, .foregroundColor: color]))
        } else {
            result.append(NSAttributedString(string: timeLabel, attributes: [.font: font, .foregroundColor: color]))
        }

        cursor = range.upperBound
    }
    if cursor < rawBody.endIndex {
        result.append(NSAttributedString(string: String(rawBody[cursor...]), attributes: [.font: font, .foregroundColor: color]))
    }
    return result
}

// MARK: - Calendar account colors (matches swiftCALENDAR's calendar_accounts.json exactly)

struct CalendarAccount: Codable {
    var id: String = UUID().uuidString
    var name: String = ""
    var url: String = ""
    var enabled: Bool = true
    var colorIndex: Int = -1
    var type: String = "ics"
    var lat: String = ""
    var lon: String = ""
}

// Same 7 colors and same order as swiftCALENDAR's own calendarColorPalette, converted from
// its ANSI codes to RGB. Cyan/Green/Magenta are swiftCALENDAR's own standard-16-color ANSI
// codes (terminal-theme-dependent by nature, so these are reasonable approximations);
// Orange/Pink/Teal/Mint are its 256-color-cube codes, converted with the exact same cube
// math used earlier for swiftCT's own sidebar colors.
let calendarColorPalette: [NSColor] = [
    NSColor(calibratedRed: 0/255, green: 200/255, blue: 200/255, alpha: 1.0),    // Cyan
    NSColor(calibratedRed: 76/255, green: 175/255, blue: 80/255, alpha: 1.0),    // Green
    NSColor(calibratedRed: 191/255, green: 90/255, blue: 242/255, alpha: 1.0),   // Magenta
    NSColor(calibratedRed: 255/255, green: 135/255, blue: 0/255, alpha: 1.0),    // Orange
    NSColor(calibratedRed: 255/255, green: 135/255, blue: 175/255, alpha: 1.0),  // Pink
    NSColor(calibratedRed: 0/255, green: 135/255, blue: 135/255, alpha: 1.0),    // Teal
    NSColor(calibratedRed: 135/255, green: 255/255, blue: 175/255, alpha: 1.0),  // Mint
]

// MARK: - Read-only note detail window
// Styled like the main window now (background/foreground, titled/closable) rather than a
// bespoke "sticky note" look — swiftVIEW isn't a notes app, so its popups shouldn't look
// like one either. Still read-only: isEditable = false, no save-on-close path at all.

final class NoteDetailWindow: NSWindow, NSWindowDelegate {
    weak var appDelegate: AppDelegate?
    var noteKey: String
    var note: Note
    var plaintextBody: String
    var reverseColorsMenuItem: NSMenuItem?

    init(noteKey: String, note: Note, plaintextBody: String, appDelegate: AppDelegate) {
        self.noteKey = noteKey
        self.note = note
        self.plaintextBody = plaintextBody
        self.appDelegate = appDelegate

        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 280, height: 340)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        delegate = self
        title = note.title.isEmpty ? "(untitled)" : note.title

        let cascade = CGFloat((appDelegate.openDetailWindows.count % 8) * 24)
        setFrameOrigin(NSPoint(x: 200 + cascade, y: 400 - cascade))

        rebuildContent()
        makeKeyAndOrderFront(nil)
    }

    // Tears down and rebuilds the whole window's content at the app's current scaleFactor
    // and color scheme — called from init and again whenever Bigger/Smaller/Reverse Colors
    // is chosen from this window's own context menu, mirroring the main window's own
    // rebuild-in-place approach exactly.
    func rebuildContent() {
        guard let appDelegate = appDelegate else { return }
        let s = appDelegate.scaleFactor
        let width: CGFloat = 280 * s
        let height: CGFloat = 340 * s

        let contentFrame = NSRect(x: 0, y: 0, width: width, height: height)
        let fullFrameRect = frameRect(forContentRect: contentFrame)
        let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
        let newOrigin = NSPoint(x: oldCenter.x - fullFrameRect.width / 2, y: oldCenter.y - fullFrameRect.height / 2)
        setFrame(NSRect(origin: newOrigin, size: fullFrameRect.size), display: true)

        isOpaque = false
        backgroundColor = appDelegate.background.withAlphaComponent(appDelegate.isDarkMode ? appDelegate.sharedDarkModeOpacity : 1.0)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = appDelegate.background.cgColor
        content.menu = buildContextMenu()
        contentView = content

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM d"

        var y = height - 20 * s
        func addLine(_ text: String, icon: String) {
            guard !text.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: 12 * s)
            let labelWidth = width - 46 * s
            // Measure the actual wrapped height this text needs at this width, rather than
            // assuming every line fits in one fixed-height slot.
            let boundingRect = (text as NSString).boundingRect(
                with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            let textHeight = max(16 * s, ceil(boundingRect.height) + 2 * s)

            y -= textHeight
            let iconView = NSImageView(frame: NSRect(x: 12 * s, y: y + textHeight - 16 * s, width: 16 * s, height: 16 * s))
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            iconView.contentTintColor = appDelegate.foreground
            content.addSubview(iconView)

            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = appDelegate.foreground
            label.frame = NSRect(x: 34 * s, y: y, width: labelWidth, height: textHeight)
            content.addSubview(label)

            y -= 8 * s   // gap before the next line
        }

        // Name
        addLine(note.title.isEmpty ? "(untitled)" : note.title, icon: "note.text")

        // Date created
        addLine("Created \(dateFormatter.string(from: note.dateCreated))", icon: "calendar")

        // Due date — only shown if the note actually has one
        if let due = note.dueDate {
            addLine("Due \(dateFormatter.string(from: due))", icon: "bell")
        }

        // Tags — only shown if there are any
        if !note.tags.isEmpty {
            addLine(note.tags.joined(separator: ", "), icon: "tag")
        }

        y -= 4 * s   // a little extra breathing room before the body starts

        // The note/description itself, scrollable since it can run arbitrarily long unlike
        // the fixed metadata rows above it.
        let bodyTop = y
        let bodyBottom = 10 * s
        let scroll = NSScrollView(frame: NSRect(x: 10 * s, y: bodyBottom, width: width - 20 * s, height: max(40 * s, bodyTop - bodyBottom)))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false   // the entire point of swiftVIEW — look, don't touch
        textView.isSelectable = true  // still fine to select/copy text out of it
        textView.isRichText = true    // needed for the inline clock-icon attachments below
        let bodyFont = NSFont.systemFont(ofSize: 13 * s)
        textView.font = bodyFont
        textView.textColor = appDelegate.foreground
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(
            attributedBody(plaintextBody, font: bodyFont, color: appDelegate.foreground, iconSize: 13 * s)
        )

        scroll.documentView = textView
        content.addSubview(scroll)
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bigger", action: #selector(growWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Smaller", action: #selector(shrinkWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "")
        reverseItem.state = (appDelegate?.isDarkMode ?? true) ? .off : .on
        reverseColorsMenuItem = reverseItem
        menu.addItem(reverseItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeThisWindow), keyEquivalent: "")
        return menu
    }

    // Bigger/Smaller/Reverse Colors are app-wide settings, same as the main window's own —
    // so triggering them here rebuilds the main window too, keeping everything visually
    // consistent, not just this one popup.
    @objc func growWindow() {
        appDelegate?.growWindow()
        rebuildContent()
    }

    @objc func shrinkWindow() {
        appDelegate?.shrinkWindow()
        rebuildContent()
    }

    @objc func toggleColorMode() {
        appDelegate?.toggleColorMode()
        rebuildContent()
    }

    @objc func closeThisWindow() { close() }

    func windowWillClose(_ notification: Notification) {
        appDelegate?.openDetailWindows.removeValue(forKey: noteKey)
    }
}

// MARK: - Read-only event detail window
// Same treatment as NoteDetailWindow — titled, main-window color scheme, rebuild-in-place
// Bigger/Smaller/Reverse Colors, Close instead of a bespoke close button.

final class EventDetailWindow: NSWindow, NSWindowDelegate {
    weak var appDelegate: AppDelegate?
    var eventKey: String
    var event: CalendarEvent
    var reverseColorsMenuItem: NSMenuItem?

    init(eventKey: String, event: CalendarEvent, appDelegate: AppDelegate) {
        self.eventKey = eventKey
        self.event = event
        self.appDelegate = appDelegate

        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 280, height: 420)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        delegate = self
        title = EventDetailWindow.windowTitle(for: event)

        let cascade = CGFloat((appDelegate.openDetailWindows.count % 8) * 24)
        setFrameOrigin(NSPoint(x: 260 + cascade, y: 360 - cascade))

        rebuildContent()
        makeKeyAndOrderFront(nil)
    }

    // "METAR KCLT" / "TAF KCLT" (the account's own calendarName) becomes "METAR: KCLT" /
    // "TAF: KCLT" for the window title — everything else just uses the event's own title.
    static func windowTitle(for event: CalendarEvent) -> String {
        let isWeather = event.calendarName.hasPrefix("METAR") || event.calendarName.hasPrefix("TAF")
        if isWeather, let airport = knownAirports[event.location.uppercased()], !airport.display.isEmpty {
            return airport.display
        }
        if event.calendarName.hasPrefix("METAR") {
            return "METAR: \(event.location)"
        }
        if event.calendarName.hasPrefix("TAF") {
            return "TAF: \(event.location)"
        }
        return event.title.isEmpty ? "(untitled event)" : event.title
    }

    func rebuildContent() {
        guard let appDelegate = appDelegate else { return }
        let s = appDelegate.scaleFactor
        let width: CGFloat = 280 * s
        let height: CGFloat = 420 * s

        let contentFrame = NSRect(x: 0, y: 0, width: width, height: height)
        let fullFrameRect = frameRect(forContentRect: contentFrame)
        let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
        let newOrigin = NSPoint(x: oldCenter.x - fullFrameRect.width / 2, y: oldCenter.y - fullFrameRect.height / 2)
        setFrame(NSRect(origin: newOrigin, size: fullFrameRect.size), display: true)

        isOpaque = false
        backgroundColor = appDelegate.background.withAlphaComponent(appDelegate.isDarkMode ? appDelegate.sharedDarkModeOpacity : 1.0)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = appDelegate.background.cgColor
        content.menu = buildContextMenu()
        contentView = content

        // Content gets collected here first, then measured and built in one correctly-sized
        // pass below — matching the main window's own approach (know the total size before
        // creating anything), rather than building into an oversized canvas and trying to
        // trim/reposition afterward, which is what an earlier version of this did.
        //
        // Each line stores the ACTUAL NSTextField that will be displayed, measured directly
        // via cell.cellSize(forBounds:) at the moment it's created — not a separate estimate
        // calculated from the raw string. A prior version measured with a plain
        // NSString.boundingRect() calculation done independently of the real label, and that
        // estimate came out shorter than what the label actually rendered at, compounding
        // across multiple wrapped lines until the last line or two ended up positioned
        // outside the container's own bounds and clipped. Reusing the same object for both
        // measuring and displaying removes any chance of that gap recurring.
        struct MeasuredLine {
            let label: NSTextField?
            let height: CGFloat
            let icon: String
            var trendIcon: String? = nil
            var trendColor: NSColor? = nil
            var textWidth: CGFloat? = nil
            var customDraw: ((NSRect) -> NSView)? = nil
            var iconYOffset: CGFloat? = nil
        }
        var lines: [MeasuredLine] = []
        let labelWidth = width - 46 * s

        let isWeather = event.decodedWeather != nil
        let isMetar = event.calendarName.hasPrefix("METAR")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "EEE MMM d, h:mm a"

        // "(all day)" is a calendar-placement technicality (every METAR/TAF is filed as an
        // all-day entry so it has somewhere to sit), not something meaningful to show here —
        // the actual observation/issuance time (parsed from the raw text itself) is far more
        // useful and gets its own line below instead.
        let timeText = isWeather
            ? dateFormatter.string(from: event.startTime)
            : (event.isAllDay
                ? (dateFormatter.string(from: event.startTime)) + " (all day)"
                : "\(timeFormatter.string(from: event.startTime)) – \(DateFormatter.localizedString(from: event.endTime, dateStyle: .none, timeStyle: .short))")

        func addLine(_ text: String, icon: String) {
            guard !text.isEmpty else { return }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = NSFont.systemFont(ofSize: 12 * s)
            label.textColor = appDelegate.foreground
            let fitSize = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: .greatestFiniteMagnitude))
            let height = max(16 * s, ceil(fitSize.height) + 2 * s)
            lines.append(MeasuredLine(label: label, height: height, icon: icon))
        }
        func addAttributedLine(_ attributed: NSAttributedString, icon: String) {
            guard attributed.length > 0 else { return }
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = attributed
            let fitSize = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: .greatestFiniteMagnitude))
            let height = max(16 * s, ceil(fitSize.height) + 2 * s)
            lines.append(MeasuredLine(label: label, height: height, icon: icon))
        }

        // Same measurement approach as addLine, but with a small colored trend indicator
        // (green rising triangle / yellow steady dash / red falling triangle) on the right
        // side of the row — used only for the barometer reading. Measures at the same
        // narrowed width the build pass will actually use for this row, not the full
        // labelWidth — otherwise the text could wrap differently once narrowed to make room
        // for the trend icon, reintroducing the exact height-mismatch bug just fixed above.
        let trendLabelWidth = labelWidth - 22 * s
        func addLineWithTrend(_ text: String, icon: String, trendIcon: String, trendColor: NSColor) {
            guard !text.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: 12 * s)
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = appDelegate.foreground
            let fitSize = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: trendLabelWidth, height: .greatestFiniteMagnitude))
            let height = max(16 * s, ceil(fitSize.height) + 2 * s)
            // Natural single-line width, capped at trendLabelWidth in the unlikely case the
            // text is long enough to wrap — this is what actually positions the trend icon,
            // rather than assuming the text fills the whole reserved label width.
            let naturalWidth = min(trendLabelWidth, ceil((text as NSString).size(withAttributes: [.font: font]).width))
            lines.append(MeasuredLine(label: label, height: height, icon: icon, trendIcon: trendIcon, trendColor: trendColor, textWidth: naturalWidth))
        }

        // Builds a min/max/current range indicator — a horizontal track with a dot marking
        // where the current value sits between low and high, plus a small "current, now"
        // line underneath. Same idea as swiftSTOCKS' own 52-week range bar (a line + dot
        // between a min and max), just drawn as real AppKit views here instead of terminal
        // box-drawing characters, since this app has an actual graphical canvas to work with.
        func addRangeBar(low: Int, high: Int, current: Int, currentLabel: String, icon: String) {
            let rowHeight: CGFloat = 40 * s
            let font = NSFont.systemFont(ofSize: 13 * s)
            let smallFont = NSFont.systemFont(ofSize: 11 * s)
            // The generic build-loop formula positions every row's icon 16pt below the
            // row's own top edge, which is correct for a normal single-line row but leaves
            // this icon sitting well above the track itself, since this row is taller (46pt)
            // and the track sits lower within it, with the "now" label below that. This is
            // the offset that actually centers the icon on trackY (= frame.height - 14*s,
            // defined again below) instead.
            let iconYOffset: CGFloat = rowHeight - 18 * s

            let draw: (NSRect) -> NSView = { frame in
                let container = NSView(frame: frame)

                let lowText = "\(low)°F"
                let highText = "\(high)°F"
                let lowWidth = ceil((lowText as NSString).size(withAttributes: [.font: font]).width)
                let highWidth = ceil((highText as NSString).size(withAttributes: [.font: font]).width)

                let trackY = frame.height - 14 * s
                let trackX0: CGFloat = lowWidth + 10 * s
                let trackX1: CGFloat = frame.width - highWidth - 10 * s
                let trackWidth = max(20 * s, trackX1 - trackX0)

                let lowLabel = NSTextField(labelWithString: lowText)
                lowLabel.font = font
                lowLabel.textColor = appDelegate.foreground
                lowLabel.frame = NSRect(x: 0, y: trackY - 8 * s, width: lowWidth, height: 16 * s)
                container.addSubview(lowLabel)

                let track = NSView(frame: NSRect(x: trackX0, y: trackY - 1.5 * s, width: trackWidth, height: 3 * s))
                track.wantsLayer = true
                track.layer?.backgroundColor = appDelegate.foreground.withAlphaComponent(0.3).cgColor
                track.layer?.cornerRadius = 1.5 * s
                container.addSubview(track)

                let highLabel = NSTextField(labelWithString: highText)
                highLabel.font = font
                highLabel.textColor = appDelegate.foreground
                highLabel.frame = NSRect(x: frame.width - highWidth, y: trackY - 8 * s, width: highWidth, height: 16 * s)
                container.addSubview(highLabel)

                // Dot position — clamped to [0, 1] in case current somehow falls outside
                // the low-high range (shouldn't happen given current is drawn from the
                // same reading pool low/high come from, but a real day boundary edge case
                // isn't worth risking a dot rendered off the end of the track for).
                let pct: CGFloat = high > low ? CGFloat(current - low) / CGFloat(high - low) : 0.5
                let clampedPct = max(0, min(1, pct))
                let dotSize: CGFloat = 12 * s
                let dotX = trackX0 + trackWidth * clampedPct - dotSize / 2
                let dot = NSView(frame: NSRect(x: dotX, y: trackY - dotSize / 2, width: dotSize, height: dotSize))
                dot.wantsLayer = true
                dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
                dot.layer?.cornerRadius = dotSize / 2
                container.addSubview(dot)

                let nowLabel = NSTextField(labelWithString: currentLabel)
                nowLabel.font = smallFont
                nowLabel.textColor = appDelegate.foreground.withAlphaComponent(0.7)
                let nowLabelWidth = ceil((currentLabel as NSString).size(withAttributes: [.font: smallFont]).width)
                let dotCenterX = dotX + dotSize / 2
                let idealX = dotCenterX - nowLabelWidth / 2
                // Clamped so the label can't run off either edge of the card when the dot
                // sits close to the low or high end of the range.
                let nowLabelX = max(0, min(frame.width - nowLabelWidth, idealX))
                nowLabel.frame = NSRect(x: nowLabelX, y: 2 * s, width: nowLabelWidth, height: 14 * s)
                container.addSubview(nowLabel)

                return container
            }

            lines.append(MeasuredLine(label: nil, height: rowHeight, icon: icon, customDraw: draw, iconYOffset: iconYOffset))
        }

        // 1. Calendar Name
        addLine(event.calendarName, icon: event.calendarName == "Birthdays" ? "birthday.cake" : "calendar")

        // 2. Date
        addLine(timeText, icon: "clock")

        // 3. Time — the real observation/issuance timestamp, parsed straight from the raw
        // text's own leading DDHHMMZ group. This is what actually tells you how current the
        // reading is, which "All day" on its own never did. METAR also gets the local time
        // added in red parentheses alongside the UTC time, same red-for-derived convention
        // as the temp line's Fahrenheit conversion — UTC is what's actually in the raw
        // observation/issuance, local time is a convenience conversion on top of it. Same
        // treatment for both METAR and TAF now — only the label differs (Observed/Issued).
        if isWeather, let obsTime = parseObservationTime(from: event.title) {
            let utcFormatter = DateFormatter()
            utcFormatter.dateFormat = "h:mm a 'UTC'"
            utcFormatter.timeZone = TimeZone(identifier: "UTC")
            let label = isMetar ? "Observed" : "Issued"
            let utcText = "\(label) \(utcFormatter.string(from: obsTime))"

            let localFormatter = DateFormatter()
            localFormatter.dateFormat = "h:mm a"
            localFormatter.timeZone = TimeZone.current
            let localText = "   [\(localFormatter.string(from: obsTime))]"

            let attributed = NSMutableAttributedString(
                string: utcText,
                attributes: [.font: NSFont.systemFont(ofSize: 12 * s), .foregroundColor: appDelegate.foreground]
            )
            attributed.append(NSAttributedString(
                string: localText,
                attributes: [.font: NSFont.systemFont(ofSize: 12 * s), .foregroundColor: NSColor.systemRed]
            ))
            addAttributedLine(attributed, icon: "clock.arrow.circlepath")
        }

        // 4. Location — the airport's real name (from known_airports.json) next to the bare
        // ICAO code, instead of just the code alone.
        if isWeather, let airport = knownAirports[event.location.uppercased()], !airport.airportName.isEmpty {
            addLine("\(event.location) — \(airport.airportName)", icon: "mappin.and.ellipse")
        } else {
            addLine(event.location, icon: "mappin.and.ellipse")
        }

        // 4b. Raw METAR/TAF code — this got dropped somewhere along the way through the
        // reordering; the popup was only ever showing the decoded summary, never the actual
        // source text it was decoded from.
        if isWeather {
            addLine(event.title, icon: "airplane")
        }

        // 5. Forecast (decoded)
        if let weather = event.decodedWeather { addLine(weather, icon: "cloud.sun") }
        if !event.notes.isEmpty && event.decodedWeather == nil { addLine(event.notes, icon: "text.alignleft") }

        // 6. Temp — Celsius (parsed from the raw temp/dewpoint group) first, then the
        // Fahrenheit conversion in red in brackets, matching the exact convention already
        // used in the terminal's own agenda view ("31/21 [88°F/70°F]") — red there means
        // "derived/decoded, not literally present in the raw feed," same reasoning here.
        // Applies to both METAR and TAF, not just METAR. Wrapped in an outer isWeather check
        // — without it, a regular (non-weather) event with its own notes would fall through
        // to the "couldn't parse, show notes anyway" fallback below and show its notes a
        // second time with a thermometer icon, which is exactly what was happening.
        if isWeather {
            if let (tempC, dewC) = parseTempCelsius(from: event.title) {
                let fahrenheitBracket = event.notes.isEmpty ? "" : "   [\(event.notes)]"
                let plainPart = "\(tempC)°C/\(dewC)°C"
                let attributed = NSMutableAttributedString(
                    string: plainPart,
                    attributes: [.font: NSFont.systemFont(ofSize: 12 * s), .foregroundColor: appDelegate.foreground]
                )
                if !fahrenheitBracket.isEmpty {
                    attributed.append(NSAttributedString(
                        string: fahrenheitBracket,
                        attributes: [.font: NSFont.systemFont(ofSize: 12 * s), .foregroundColor: NSColor.systemRed]
                    ))
                }
                addAttributedLine(attributed, icon: "thermometer.medium")

                // Humidity — METAR only, computed from the same temp/dewpoint just parsed
                // above rather than reparsing. TAF's temp/dewpoint-shaped field isn't a true
                // observed dewpoint the way METAR's is, so it doesn't get this line.
                if isMetar {
                    let rh = relativeHumidity(tempC: Double(tempC), dewpointC: Double(dewC))
                    addLine("\(rh)% relative humidity", icon: "humidity")
                }
            } else if !event.notes.isEmpty {
                // Couldn't parse Celsius from the raw text — fall back to showing whatever
                // Fahrenheit summary is already available rather than dropping the line entirely.
                addLine(event.notes, icon: "thermometer.medium")
            }
        }

        // 6b. Sunrise/Sunset — both METAR and TAF get this (today's on the METAR card,
        // tomorrow's on the TAF card, since sunrise/sunset itself was computed for
        // whichever date that event actually represents). Calculated locally by
        // calendar_sync.py rather than fetched — NWS doesn't expose this data despite
        // computing it internally, confirmed directly with their API team. Optional
        // fields, so older calendar.json entries without them just don't show these lines.
        if isWeather {
            switch (event.sunrise, event.sunset) {
            case let (.some(sunrise), .some(sunset)):
                let font = NSFont.systemFont(ofSize: 12 * s)
                let combined = NSMutableAttributedString(
                    string: "\(sunrise)    ",
                    attributes: [.font: font, .foregroundColor: appDelegate.foreground]
                )
                if let sunsetIcon = tintedSymbolImage(systemName: "sunset", color: appDelegate.foreground, pointSize: font.pointSize * 0.85) {
                    let attachment = NSTextAttachment()
                    attachment.image = sunsetIcon
                    combined.append(NSAttributedString(attachment: attachment))
                    combined.append(NSAttributedString(string: " \(sunset)", attributes: [.font: font, .foregroundColor: appDelegate.foreground]))
                } else {
                    combined.append(NSAttributedString(string: sunset, attributes: [.font: font, .foregroundColor: appDelegate.foreground]))
                }
                addAttributedLine(combined, icon: "sunrise")
            case let (.some(sunrise), nil):
                addLine(sunrise, icon: "sunrise")
            case let (nil, .some(sunset)):
                addLine(sunset, icon: "sunset")
            case (nil, nil):
                break
            }
        }

        // 7. Barometer — METAR only (TAF is a forecast issued once, there's no "current
        // reading" to compare against). Compares against the most recent reading from a
        // different calendar day — in practice this is almost always yesterday's own
        // last reading, since today's day-of doesn't count as "previous." Uses
        // mostRecentReading (true observation time) rather than startTime, since that
        // other day could itself now have several readings stored, not just one.
        if isMetar,
           let currentAlt = parseAltimeter(from: event.title),
           let previousReading = mostRecentReading(appDelegate.metarEvents.filter {
                $0.location == event.location && !Calendar.current.isDate($0.startTime, inSameDayAs: event.startTime)
           }),
           let previousAlt = parseAltimeter(from: previousReading.title) {
            let delta = currentAlt - previousAlt
            let (trendIcon, trendColor, trendWord): (String, NSColor, String)
            if delta > 0.02 { (trendIcon, trendColor, trendWord) = ("arrowtriangle.up.fill", .systemGreen, "rising") }
            else if delta < -0.02 { (trendIcon, trendColor, trendWord) = ("arrowtriangle.down.fill", .systemRed, "falling") }
            else { (trendIcon, trendColor, trendWord) = ("circle.fill", .systemYellow, "steady") }
            addLineWithTrend(String(format: "%.2f inHg, %@ (was %.2f)", currentAlt, trendWord, previousAlt),
                              icon: "barometer", trendIcon: trendIcon, trendColor: trendColor)
        }

        // 8. 30-Day Temp Range — METAR only. Rolling 30-day window rather than calendar
        // month, so it doesn't reset to near-empty on the 1st of every month once there's
        // real history behind it — it naturally fills in as data accumulates instead.
        // "Current" reuses this event's own temp from .notes (same field the temp line
        // above already reads), not a separately-computed most-recent value, so the two
        // stay consistent with each other on the same card.
        if isMetar {
            func fahrenheitTemp(from notes: String) -> Int? {
                guard let firstPart = notes.split(separator: "/").first else { return nil }
                let digitsOnly = firstPart.filter { $0.isNumber || $0 == "-" }
                return Int(digitsOnly)
            }

            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date.distantPast
            let recentReadings = appDelegate.metarEvents.filter {
                $0.location == event.location && $0.startTime >= thirtyDaysAgo
            }
            let temps = recentReadings.compactMap { fahrenheitTemp(from: $0.notes) }
            if let low = temps.min(), let high = temps.max(), let current = fahrenheitTemp(from: event.notes) {
                addRangeBar(low: low, high: high, current: current, currentLabel: "\(current)°F now", icon: "arrow.up.arrow.down.circle")
            }
        }

        let topMargin: CGFloat = 20 * s
        let lineGap: CGFloat = 8 * s
        let totalContentHeight = lines.reduce(topMargin) { $0 + $1.height + lineGap }
        // At least window-height, even when content is shorter — otherwise NSScrollView
        // anchors a too-short document to the BOTTOM of the viewport by default, which is
        // what produced the dead space sitting at the TOP instead of the bottom on shorter
        // cards. Rows are drawn from the top of this container either way, so any extra
        // room this adds naturally ends up at the bottom, which reads normally.
        let scrollContentHeight = max(height, totalContentHeight)

        let scrollContent = NSView(frame: NSRect(x: 0, y: 0, width: width, height: scrollContentHeight))
        var y = scrollContentHeight - topMargin
        for line in lines {
            y -= line.height

            let iconView = NSImageView(frame: NSRect(x: 12 * s, y: y + line.height - (line.iconYOffset ?? 16 * s), width: 16 * s, height: 16 * s))
            iconView.image = NSImage(systemSymbolName: line.icon, accessibilityDescription: nil)
            iconView.contentTintColor = appDelegate.foreground
            scrollContent.addSubview(iconView)

            // Trailing colored trend indicator (barometer row only) — positioned right after
            // where the text actually ends, not at the edge of the reserved label width,
            // which was leaving a large unwanted gap before it.
            var thisLabelWidth = labelWidth
            if let trendIcon = line.trendIcon, let trendColor = line.trendColor {
                thisLabelWidth = trendLabelWidth
                let textEndX = 34 * s + (line.textWidth ?? thisLabelWidth)
                let iconGap: CGFloat = 10 * s   // roughly 2-3 spaces at this font size
                let trendView = NSImageView(frame: NSRect(x: textEndX + iconGap, y: y + line.height - 16 * s, width: 16 * s, height: 16 * s))
                trendView.image = NSImage(systemSymbolName: trendIcon, accessibilityDescription: nil)
                trendView.contentTintColor = trendColor
                scrollContent.addSubview(trendView)
            }

            if let label = line.label {
                label.frame = NSRect(x: 34 * s, y: y, width: thisLabelWidth, height: line.height)
                scrollContent.addSubview(label)
            } else if let customDraw = line.customDraw {
                let customFrame = NSRect(x: 34 * s, y: y, width: thisLabelWidth, height: line.height)
                scrollContent.addSubview(customDraw(customFrame))
            }

            y -= lineGap
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay   // invisible until actively scrolling, then fades in
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = scrollContent
        content.addSubview(scroll)

        // Explicitly scroll to the top — NSScrollView doesn't do this automatically just
        // because documentView was set, which is what caused the blank-gap-at-top bug before.
        if scrollContentHeight > height {
            let scrollToY = scrollContentHeight - height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scrollToY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bigger", action: #selector(growWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Smaller", action: #selector(shrinkWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "")
        reverseItem.state = (appDelegate?.isDarkMode ?? true) ? .off : .on
        reverseColorsMenuItem = reverseItem
        menu.addItem(reverseItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeThisWindow), keyEquivalent: "")
        return menu
    }

    @objc func growWindow() {
        appDelegate?.growWindow()
        rebuildContent()
    }

    @objc func shrinkWindow() {
        appDelegate?.shrinkWindow()
        rebuildContent()
    }

    @objc func toggleColorMode() {
        appDelegate?.toggleColorMode()
        rebuildContent()
    }

    @objc func closeThisWindow() { close() }

    func windowWillClose(_ notification: Notification) {
        appDelegate?.openDetailWindows.removeValue(forKey: eventKey)
    }
}

// ─────────────────────────────────────────────────────────────
// ABOUT PANEL — same pattern already used in swiftEYES/swiftCLOCK/swiftSYSINFO
// ─────────────────────────────────────────────────────────────

final class AboutWindowController: NSWindowController {
    convenience init(appName: String, tagline: String, version: String) {
        let panelSize = NSSize(width: 300, height: 260)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About \(appName)"
        panel.isReleasedWhenClosed = false
        panel.center()

        let contentView = NSView(frame: NSRect(origin: .zero, size: panelSize))

        let iconView = NSImageView(frame: NSRect(x: (panelSize.width - 60) / 2, y: 188, width: 60, height: 60))
        iconView.image = NSApplication.shared.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = .boldSystemFont(ofSize: 18)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: 164, width: panelSize.width, height: 20)
        contentView.addSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: 144, width: panelSize.width, height: 16)
        contentView.addSubview(versionLabel)

        let taglineLabel = NSTextField(wrappingLabelWithString: tagline)
        taglineLabel.font = .systemFont(ofSize: 12)
        taglineLabel.alignment = .center
        taglineLabel.textColor = .labelColor
        taglineLabel.frame = NSRect(x: 24, y: 50, width: panelSize.width - 48, height: 90)
        contentView.addSubview(taglineLabel)

        let okButton = NSButton(title: "OK", target: nil, action: #selector(NSWindow.performClose(_:)))
        okButton.bezelStyle = .rounded
        okButton.frame = NSRect(x: (panelSize.width - 80) / 2, y: 14, width: 80, height: 28)
        okButton.keyEquivalent = "\r"
        contentView.addSubview(okButton)

        panel.contentView = contentView
        self.init(window: panel)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var notes: [Note] = []
    var events: [CalendarEvent] = []
    var metarEvents: [CalendarEvent] = []
    var notebookKey: SymmetricKey!
    var notesFileURL: URL!
    var calendarFileURL: URL!
    var localEventsFileURL: URL!
    var metarHistoryFileURL: URL!
    var calendarAccountsFileURL: URL!
    var calendarAccounts: [CalendarAccount] = []
    var sharedDarkModeOpacity: CGFloat = 1.0
    var listContainer: NSView!
    var glanceScrollView: NSScrollView!
    var refreshTimer: Timer?
    var scaleFactor: CGFloat = 1.0
    var isDarkMode = true
    var useDotStyle = true
    var aboutWindowController: AboutWindowController?
    var reverseColorsMenuItem: NSMenuItem?
    var contextMenuReverseItem: NSMenuItem?
    var dotStyleMenuItem: NSMenuItem?
    var contextMenuDotStyleItem: NSMenuItem?

    // Keyed by "note:<index>" or "event:<uuid>" — a stable-enough key for tracking which
    // detail windows are already open so a second click brings the existing one forward
    // instead of opening a duplicate.
    var openDetailWindows: [String: NSWindow] = [:]

    var background: NSColor { isDarkMode ? darkBackground : lightBackground }
    var foreground: NSColor { isDarkMode ? darkForeground : lightForeground }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        sharedDarkModeOpacity = loadSharedTerminalOpacity()

        guard let root = suiteRoot else {
            fail("Could not find swiftCORE", "swiftVIEW couldn't locate a swiftCORE binary in a sibling folder. Make sure swiftVIEW is sitting inside the swiftSUITE folder.")
        }
        notesFileURL = root.appendingPathComponent("swiftNOTES").appendingPathComponent("notes.json")
        calendarFileURL = root.appendingPathComponent("swiftCALENDAR").appendingPathComponent("calendar.json")
        localEventsFileURL = root.appendingPathComponent("swiftCALENDAR").appendingPathComponent("local_events.json")
        metarHistoryFileURL = root.appendingPathComponent("swiftCALENDAR").appendingPathComponent("metar_history.json")
        calendarAccountsFileURL = root.appendingPathComponent("swiftCALENDAR").appendingPathComponent("calendar_accounts.json")

        guard let sessionKey = readCoreSessionKey(appID: "swiftNOTES") else {
            fail("Session expired", "Please log in via swiftCORE first, then relaunch swiftVIEW.")
        }
        notebookKey = sessionKey

        loadNotes()
        loadEvents()
        loadLocalEvents()
        loadBirthdayOverlay()
        loadMetarHistory()
        loadCalendarAccounts()

        buildMainWindow()
        setUpMainMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Same 20-second interval swiftSYSINFO/swiftSTICKY already use — swiftVIEW has no
        // editing at all, so there's no "don't reload out from under an in-progress edit"
        // concern the way swiftSTICKY has; always safe to just refresh.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.loadNotes()
            self?.loadEvents()
            self?.loadLocalEvents()
            self?.loadBirthdayOverlay()
            self?.loadMetarHistory()
            self?.loadCalendarAccounts()
            self?.refreshList()
        }
    }

    func fail(_ title: String, _ message: String) -> Never {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        exit(1)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        let openWindows = Array(openDetailWindows.values)
        for w in openWindows { w.close() }
    }

    func windowDidResize(_ notification: Notification) {
        guard let resized = notification.object as? NSWindow, resized == window else { return }
        refreshList()
    }

    // MARK: Data loading

    func loadNotes() {
        guard let data = try? Data(contentsOf: notesFileURL),
              let notebookFile = try? JSONDecoder().decode(NotebookFile.self, from: data),
              let decryptedCanary = try? NotebookCrypto.decrypt(notebookFile.canary, key: notebookKey),
              decryptedCanary == NotebookCrypto.canaryPlaintext else {
            return   // notes.json missing/unreadable — leave `notes` as whatever it was (likely empty on first failed load)
        }
        notes = notebookFile.notes
    }

    func loadEvents() {
        guard let data = try? Data(contentsOf: calendarFileURL) else { return }
        // Decoded one element at a time rather than the whole array in a single
        // decoder.decode([CalendarEvent].self, ...) call — if even one entry in
        // calendar.json fails to decode (a malformed date, an unexpected field type),
        // that used to silently discard the entire array and leave `events` stuck on
        // stale data from the last successful load, hiding every event, not just the
        // broken one. Now a bad entry is skipped and logged, everything else still loads.
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("swiftVIEW: couldn't parse calendar.json as a JSON array at all")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded: [CalendarEvent] = []
        for (index, raw) in rawArray.enumerated() {
            guard let entryData = try? JSONSerialization.data(withJSONObject: raw),
                  let event = try? decoder.decode(CalendarEvent.self, from: entryData) else {
                let title = raw["title"] as? String ?? "(unknown)"
                print("swiftVIEW: skipped calendar.json entry \(index) (\"\(title)\") — failed to decode")
                continue
            }
            decoded.append(event)
        }
        events = decoded
    }

    // local_events.json is a completely separate file from calendar.json — matches
    // swiftCALENDAR's own loadLocalEvents() exactly: remove any old locals from `events`,
    // then append whatever's currently in the file. Local events (created directly in
    // swiftCALENDAR, not synced from an ICS/METAR/TAF feed) were invisible to swiftVIEW
    // entirely before this, regardless of any calendar.json decode fix, since this file was
    // simply never being read at all.
    func loadLocalEvents() {
        guard let data = try? Data(contentsOf: localEventsFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let local = try? decoder.decode([CalendarEvent].self, from: data) else { return }
        events.removeAll { $0.isLocal }
        events.append(contentsOf: local)
    }

    // Matches swiftCALENDAR's own loadBirthdayOverlay() exactly — birthdays are never
    // written to calendar.json at all. swiftCALENDAR computes them live every launch by
    // reading swiftCONTACTS' contacts.json directly (plaintext, no decryption needed) and
    // generating "It's X's Birthday" events entirely in memory, for a bounded window of
    // years around today. swiftVIEW does the exact same thing here rather than trying to
    // read them from a file that was never going to contain them.
    func loadBirthdayOverlay() {
        guard let root = suiteRoot else { return }
        let contactsURL = root.appendingPathComponent("swiftcontacts").appendingPathComponent("contacts.json")
        guard let data = try? Data(contentsOf: contactsURL) else { return }

        struct ContactBirthdayEntry: Codable {
            var firstName: String = ""
            var lastName: String = ""
            var birthdayMonthDay: String? = nil
        }
        // contacts.json is a wrapper object (kdfIterations, canary, contacts, kdfSalt,
        // formatVersion), not a bare array.
        struct ContactsFileForOverlay: Codable {
            var contacts: [ContactBirthdayEntry] = []
        }
        guard let contactsFile = try? JSONDecoder().decode(ContactsFileForOverlay.self, from: data) else { return }

        events.removeAll { $0.calendarName == "Birthdays" }

        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let yearRange = (currentYear - 3)...(currentYear + 3)

        var newBirthdayEvents: [CalendarEvent] = []
        for contact in contactsFile.contacts {
            guard let md = contact.birthdayMonthDay, !md.isEmpty else { continue }
            // Tolerates either "/" or "-" as the separator, same as swiftCALENDAR does.
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
                newBirthdayEvents.append(event)
            }
        }
        events.append(contentsOf: newBirthdayEvents)
    }

    // metar_history.json is a dict keyed by "STATION|YYYY-MM-DD", not a plain array like
    // calendar.json — matches swiftCALENDAR's own loadWeatherHistory() exactly: decode as
    // [String: CalendarEvent] and take the values.
    func loadMetarHistory() {
        guard let data = try? Data(contentsOf: metarHistoryFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Each day now stores every reading captured that day, not just one — see
        // calendar_sync.py's own fetch_metar()/sync_metar_account() for the full
        // rationale (today always reflects the latest so far; once a day becomes
        // history it's frozen with everything captured while it was still "today").
        guard let decoded = try? decoder.decode([String: [CalendarEvent]].self, from: data) else { return }
        metarEvents = decoded.values.flatMap { $0 }
    }

    func loadCalendarAccounts() {
        guard let data = try? Data(contentsOf: calendarAccountsFileURL),
              let decoded = try? JSONDecoder().decode([CalendarAccount].self, from: data) else { return }
        calendarAccounts = decoded
    }

    // The color assigned to a calendar/event row's own account — falls back to the same
    // green notes use if that account has no color assigned (colorIndex == -1) or isn't
    // found at all, so a row never ends up with no stripe rather than looking broken.
    func colorForCalendarEntry(_ calendarName: String) -> NSColor {
        guard let account = calendarAccounts.first(where: { $0.name == calendarName }),
              account.colorIndex >= 0, account.colorIndex < calendarColorPalette.count else {
            return greenbarColor
        }
        return calendarColorPalette[account.colorIndex]
    }

    // MARK: Main window

    func buildMainWindow() {
        let s = scaleFactor
        let winWidth: CGFloat = 300 * s
        let winHeight: CGFloat = 530 * s

        let frame = NSRect(x: 0, y: 0, width: winWidth, height: winHeight)
        if let existingWindow = window {
            let fullFrameRect = existingWindow.frameRect(forContentRect: frame)
            let oldFrame = existingWindow.frame
            let oldCenter = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
            let newOrigin = NSPoint(x: oldCenter.x - fullFrameRect.width / 2, y: oldCenter.y - fullFrameRect.height / 2)
            existingWindow.setFrame(NSRect(origin: newOrigin, size: fullFrameRect.size), display: true)
        } else {
            window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "swiftVIEW"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
        }

        window.isOpaque = false
        window.backgroundColor = background.withAlphaComponent(isDarkMode ? sharedDarkModeOpacity : 1.0)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = background.cgColor
        content.autoresizingMask = [.width, .height]
        content.menu = buildContextMenu()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        glanceScrollView = scroll

        let list = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))
        listContainer = list
        scroll.documentView = list
        content.addSubview(scroll)

        window.contentView = content
        refreshList()
    }

    // MARK: Merged list

    // Two clearly-labeled sections (Calendar, then Notes) rather than interleaving —
    // events and notes carry different information (times/locations vs. tags/due dates),
    // so keeping them visually separate reads more clearly than mixing them row for row.
    func refreshList() {
        let s = scaleFactor
        listContainer.frame.size.width = glanceScrollView.contentView.bounds.width
        listContainer.subviews.forEach { $0.removeFromSuperview() }

        let rowHeight: CGFloat = 32 * s
        let headerHeight: CGFloat = 28 * s
        let now = Date()
        let calendar = Calendar.current

        // Matches swiftCALENDAR's own dayKey()/eventsByDayCache exactly — a local-timezone
        // yyyy-MM-dd string comparison, not Calendar.isDateInToday/Tomorrow. All-day events
        // in particular can have a startTime that doesn't line up cleanly with local
        // wall-clock midnight depending on how it was stored, and isDateInToday/Tomorrow was
        // silently dropping them as a result — this is the exact logic already proven
        // correct in swiftCALENDAR's own agenda view, so replicating it directly rather than
        // an approximation of it.
        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"
        dayKeyFormatter.timeZone = calendar.timeZone
        let todayKey = dayKeyFormatter.string(from: now)
        let tomorrowKey = dayKeyFormatter.string(from: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

        // Today's regular events — everything for today, past or future. Past ones render
        // dimmed further down rather than being excluded outright.
        let todayRegularEvents = events
            .filter { dayKey($0.startTime) == todayKey && $0.decodedWeather == nil }
            .sorted { $0.startTime < $1.startTime }
        let tomorrowRegularEvents = events
            .filter { dayKey($0.startTime) == tomorrowKey && $0.decodedWeather == nil }
            .sorted { $0.startTime < $1.startTime }

        // Today's weather is the METAR — an actual observation, not a forecast. One entry
        // per configured METAR station (grouped by calendarName, e.g. "METAR KCLT" vs
        // "METAR KATL"), showing each station's most recent reading — not just a single
        // most-recent across every station, which was silently dropping every station but
        // one whenever more than one was configured. METAR lives in its own separate
        // file/array entirely (metar_history.json), not mixed into calendar.json at all.
        // "Most recent" now means by real observation time (mostRecentReading), not
        // startTime — every reading captured on the same day shares the same startTime
        // marker now that a full day's worth gets stored per station.
        let todayMetars: [CalendarEvent] = Dictionary(grouping: metarEvents, by: { $0.calendarName })
            .values
            .compactMap { mostRecentReading($0) }
            .sorted { $0.calendarName < $1.calendarName }

        // Tomorrow's weather is the TAF — a forecast, so it makes sense keyed to tomorrow's
        // actual date specifically. TAF entries are the ones that do live in calendar.json,
        // identified by decodedWeather being populated (isWeather itself is computed live
        // by swiftCALENDAR and never persisted). One entry per configured TAF station, same
        // fix as todayMetars above — a single global most-recent was silently dropping every
        // station but one whenever more than one TAF account was configured.
        let tomorrowTafs: [CalendarEvent] = Dictionary(
            grouping: events.filter { $0.decodedWeather != nil && dayKey($0.startTime) == tomorrowKey },
            by: { $0.calendarName }
        )
        .values
        .compactMap { $0.max { $0.startTime < $1.startTime } }
        .sorted { $0.calendarName < $1.calendarName }

        let visibleNotes = notes.enumerated().filter { !$0.element.isArchived }

        // Mirrors swiftCALENDAR's own loadDueDateOverlay() — a note with a due date shows
        // up on the calendar too, not just as a colored dot in the Notes section below.
        // Derived directly from `notes` (already loaded, already plaintext for these
        // specific fields) rather than re-reading notes.json a second time the way
        // swiftCALENDAR has to, since swiftCALENDAR doesn't otherwise have this data on hand.
        let todayDueNotes = notes.enumerated()
            .filter { !$0.element.isArchived && $0.element.dueDate != nil && dayKey($0.element.dueDate!) == todayKey }
            .sorted { $0.element.title < $1.element.title }
        let tomorrowDueNotes = notes.enumerated()
            .filter { !$0.element.isArchived && $0.element.dueDate != nil && dayKey($0.element.dueDate!) == tomorrowKey }
            .sorted { $0.element.title < $1.element.title }

        let todayRowCount = todayMetars.count + todayDueNotes.count + todayRegularEvents.count
        let tomorrowRowCount = tomorrowTafs.count + tomorrowDueNotes.count + tomorrowRegularEvents.count
        let totalRows = 1 + max(todayRowCount, 1)
            + 1 + max(tomorrowRowCount, 1)
            + 1 + visibleNotes.count + (visibleNotes.isEmpty ? 1 : 0)
        let contentHeight = CGFloat(totalRows) * rowHeight   // headers use rowHeight too, close enough for a glance list
        let totalHeight = max(listContainer.bounds.height, contentHeight)
        listContainer.frame.size.height = totalHeight

        var y = totalHeight

        func addSectionHeader(_ title: String) {
            y -= headerHeight
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = NSFont.boldSystemFont(ofSize: 11 * s)
            label.textColor = foreground.withAlphaComponent(0.55)
            label.frame = NSRect(x: 12 * s, y: y + 6 * s, width: listContainer.bounds.width - 24 * s, height: 16 * s)
            listContainer.addSubview(label)
        }

        func addRow(icon: String, title: String, striped: Bool, stripeColor: NSColor = greenbarColor, dimmed: Bool = false, useDot: Bool = false, action: Selector, key: String) {
            y -= rowHeight
            let rowY = y

            if striped && !dimmed && !useDot {
                let pillHeight: CGFloat = 24 * s
                let pillLeftInset: CGFloat = 8 * s
                let pillRightInset: CGFloat = 8 * s
                let pillY = rowY + (rowHeight - pillHeight) / 2
                let stripe = NSView(frame: NSRect(x: pillLeftInset, y: pillY, width: listContainer.bounds.width - pillLeftInset - pillRightInset, height: pillHeight))
                stripe.wantsLayer = true
                stripe.layer?.backgroundColor = stripeColor.cgColor
                stripe.layer?.cornerRadius = pillHeight / 2
                listContainer.addSubview(stripe)
            }

            let rowAlpha: CGFloat = dimmed ? 0.4 : 1.0

            let iconView = NSImageView(frame: NSRect(x: 16 * s, y: rowY + 8 * s, width: 16 * s, height: 16 * s))
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            iconView.contentTintColor = foreground.withAlphaComponent(rowAlpha)
            listContainer.addSubview(iconView)

            // Dot mode reserves room on the right for the dot itself; pill mode doesn't need
            // the extra margin since the pill sits behind the text instead of beside it.
            let labelWidth = useDot ? listContainer.bounds.width - 60 * s : listContainer.bounds.width - 50 * s
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.boldSystemFont(ofSize: 11 * s)
            label.textColor = foreground.withAlphaComponent(rowAlpha)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 38 * s, y: rowY + 9 * s, width: labelWidth, height: 14 * s)
            listContainer.addSubview(label)

            // Same 12pt dot size as swiftSYSINFO's own status dots.
            if useDot && !dimmed {
                let dotSize: CGFloat = 12 * s
                let dot = NSView(frame: NSRect(x: listContainer.bounds.width - 28 * s, y: rowY + (rowHeight - dotSize) / 2, width: dotSize, height: dotSize))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = dotSize / 2
                dot.layer?.backgroundColor = stripeColor.cgColor
                listContainer.addSubview(dot)
            }

            let button = NSButton(frame: NSRect(x: 0, y: rowY, width: listContainer.bounds.width, height: rowHeight))
            button.title = ""
            button.isBordered = false
            button.isTransparent = true
            button.identifier = NSUserInterfaceItemIdentifier(key)
            button.target = self
            button.action = action
            listContainer.addSubview(button)
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE h:mm a"

        addSectionHeader("Today")
        if todayMetars.isEmpty && todayDueNotes.isEmpty && todayRegularEvents.isEmpty {
            addEmptyRow("Nothing today", height: rowHeight, y: &y, s: s)
        } else {
            for metar in todayMetars {
                let timeText = metar.isAllDay ? "All day" : dayFormatter.string(from: metar.startTime)
                let summary = shortWeatherSummary(rawText: metar.title, fahrenheitNotes: metar.notes)
                addRow(icon: "cloud.sun", title: "\(metar.location):  \(summary)  ·  \(timeText)", striped: true,
                       stripeColor: weatherBlue, useDot: useDotStyle,
                       action: #selector(eventRowClicked(_:)), key: "event:\(metar.id.uuidString)")
            }
            // Reuses the exact same "note:<index>" key and noteRowClicked action as the
            // Notes section below — clicking one of these opens the actual note, since
            // that's what it really is, not a separate synthetic calendar event.
            for (index, note) in todayDueNotes {
                let displayTitle = note.title.isEmpty ? "(untitled)" : note.title
                addRow(icon: "bell", title: "\(displayTitle)  ·  Due today", striped: true,
                       stripeColor: dueYellow, useDot: useDotStyle,
                       action: #selector(noteRowClicked(_:)), key: "note:\(index)")
            }
            // Always striped with the event's own assigned color — same as weather always
            // being blue and local always being red. Previously this alternated based on
            // row position, which meant the very same event could show colored or plain
            // depending purely on how many weather rows happened to render before it that
            // day — an unrelated, coincidental count, not a meaningful signal.
            for event in todayRegularEvents {
                let timeText = event.isAllDay ? "All day" : dayFormatter.string(from: event.startTime)
                let isPast = !event.isAllDay && event.endTime < now
                let rowIcon = event.calendarName == "Birthdays" ? "birthday.cake" : "calendar"
                addRow(icon: rowIcon, title: "\(event.title)  ·  \(timeText)",
                       striped: true,
                       stripeColor: event.isLocal ? localRed : (event.calendarName == "Birthdays" ? birthdayPurple : colorForCalendarEntry(event.calendarName)),
                       dimmed: isPast, useDot: useDotStyle,
                       action: #selector(eventRowClicked(_:)), key: "event:\(event.id.uuidString)")
            }
        }

        addSectionHeader("Tomorrow")
        if tomorrowTafs.isEmpty && tomorrowDueNotes.isEmpty && tomorrowRegularEvents.isEmpty {
            addEmptyRow("Nothing tomorrow", height: rowHeight, y: &y, s: s)
        } else {
            for taf in tomorrowTafs {
                let timeText = taf.isAllDay ? "All day" : dayFormatter.string(from: taf.startTime)
                let summary = shortWeatherSummary(rawText: taf.title, fahrenheitNotes: taf.notes)
                addRow(icon: "cloud.sun", title: "\(taf.location):  \(summary)  ·  \(timeText)", striped: true,
                       stripeColor: weatherBlue, useDot: useDotStyle,
                       action: #selector(eventRowClicked(_:)), key: "event:\(taf.id.uuidString)")
            }
            for (index, note) in tomorrowDueNotes {
                let displayTitle = note.title.isEmpty ? "(untitled)" : note.title
                addRow(icon: "bell", title: "\(displayTitle)  ·  Due tomorrow", striped: true,
                       stripeColor: dueYellow, useDot: useDotStyle,
                       action: #selector(noteRowClicked(_:)), key: "note:\(index)")
            }
            for event in tomorrowRegularEvents {
                let timeText = event.isAllDay ? "All day" : dayFormatter.string(from: event.startTime)
                let rowIcon = event.calendarName == "Birthdays" ? "birthday.cake" : "calendar"
                addRow(icon: rowIcon, title: "\(event.title)  ·  \(timeText)",
                       striped: true,
                       stripeColor: event.isLocal ? localRed : (event.calendarName == "Birthdays" ? birthdayPurple : colorForCalendarEntry(event.calendarName)),
                       useDot: useDotStyle,
                       action: #selector(eventRowClicked(_:)), key: "event:\(event.id.uuidString)")
            }
        }

        addSectionHeader("Notes")
        if visibleNotes.isEmpty {
            addEmptyRow("No notes", height: rowHeight, y: &y, s: s)
        } else {
            for (i, entry) in visibleNotes.enumerated() {
                let (index, note) = entry
                let displayTitle = note.title.isEmpty ? "(untitled)" : note.title
                addRow(icon: "note.text", title: displayTitle, striped: i % 2 == 1,
                       action: #selector(noteRowClicked(_:)), key: "note:\(index)")
            }
        }
    }

    private func addEmptyRow(_ text: String, height: CGFloat, y: inout CGFloat, s: CGFloat) {
        y -= height
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11 * s)
        label.textColor = foreground.withAlphaComponent(0.5)
        label.frame = NSRect(x: 16 * s, y: y + 9 * s, width: listContainer.bounds.width - 32 * s, height: 14 * s)
        listContainer.addSubview(label)
    }

    // MARK: Row clicks — open a read-only detail window, or bring an already-open one forward

    @objc func noteRowClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let indexString = key.split(separator: ":").last,
              let index = Int(indexString),
              notes.indices.contains(index) else { return }

        if let existing = openDetailWindows[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let note = notes[index]
        let plaintext = (try? NotebookCrypto.decrypt(note.encryptedBody, key: notebookKey)) ?? "(couldn't decrypt this note)"
        let detail = NoteDetailWindow(noteKey: key, note: note, plaintextBody: plaintext, appDelegate: self)
        openDetailWindows[key] = detail
    }

    @objc func eventRowClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let uuidString = key.split(separator: ":").last,
              let event = (events + metarEvents).first(where: { $0.id.uuidString == uuidString }) else { return }

        if let existing = openDetailWindows[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let detail = EventDetailWindow(eventKey: key, event: event, appDelegate: self)
        openDetailWindows[key] = detail
    }

    // MARK: Context menu + main menu bar — same structure as swiftSTICKY/swiftSYSINFO

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bigger", action: #selector(growWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Smaller", action: #selector(shrinkWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "")
        reverseItem.state = isDarkMode ? .off : .on
        contextMenuReverseItem = reverseItem
        menu.addItem(reverseItem)
        let dotItem = NSMenuItem(title: "Dot Style", action: #selector(toggleDotStyle), keyEquivalent: "")
        dotItem.state = useDotStyle ? .on : .off
        contextMenuDotStyleItem = dotItem
        menu.addItem(dotItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Bigger", action: #selector(growWindow), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Smaller", action: #selector(shrinkWindow), keyEquivalent: "-")
        viewMenu.addItem(NSMenuItem.separator())
        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "i")
        reverseItem.state = isDarkMode ? .off : .on
        viewMenu.addItem(reverseItem)
        reverseColorsMenuItem = reverseItem
        let dotItem = NSMenuItem(title: "Dot Style", action: #selector(toggleDotStyle), keyEquivalent: "d")
        dotItem.state = useDotStyle ? .on : .off
        viewMenu.addItem(dotItem)
        dotStyleMenuItem = dotItem
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func growWindow() {
        scaleFactor = min(1.6, scaleFactor + 0.12)
        buildMainWindow()
    }

    @objc func shrinkWindow() {
        scaleFactor = max(0.7, scaleFactor - 0.12)
        buildMainWindow()
    }

    @objc func toggleColorMode() {
        isDarkMode.toggle()
        reverseColorsMenuItem?.state = isDarkMode ? .off : .on
        contextMenuReverseItem?.state = isDarkMode ? .off : .on
        buildMainWindow()
    }

    @objc func toggleDotStyle() {
        useDotStyle.toggle()
        dotStyleMenuItem?.state = useDotStyle ? .on : .off
        contextMenuDotStyleItem?.state = useDotStyle ? .on : .off
        refreshList()
    }

    @objc func showAboutPanel() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController(
                appName: "swiftVIEW",
                tagline: "A read-only glance companion for swiftSUITE — today's and tomorrow's calendar events, weather, and notes together in one list.",
                version: "1.0"
            )
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()