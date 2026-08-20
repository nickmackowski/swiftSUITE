// ═══════════════════════════════════════════════════════════════
// APP: swiftCT
// The main swiftSUITE terminal launcher app
// File: Sources/swiftCT/main.swift
// Updated: 2026-08-11
// ═══════════════════════════════════════════════════════════════

import AppKit
import SwiftTerm
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// ─────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────
let horizontalInset: CGFloat = 12
let fontSize: CGFloat = 14
let fontName = "Menlo"

// Every swift CLI app in the suite renders a fixed 118-character-wide layout inside a
// box (│ + 118 + │ = 120 columns total). windowWidth used to be a hardcoded pixel guess
// (1045pt) that was occasionally a few columns too narrow depending on how Menlo actually
// rendered on a given system, causing the box-drawing borders and header to wrap. Instead,
// measure the font's real character width at launch and size the window to fit
// targetColumns with a couple of columns to spare, so it's always wide enough regardless
// of font/rendering differences.
let targetColumns = 122
let targetRows = 44

private func terminalFont() -> NSFont {
    NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
}

private func measuredCharWidth() -> CGFloat {
    let sample = "M" as NSString
    return sample.size(withAttributes: [.font: terminalFont()]).width
}

private func measuredLineHeight() -> CGFloat {
    let font = terminalFont()
    return font.ascender - font.descender + font.leading
}

let windowWidth: CGFloat = (measuredCharWidth() * CGFloat(targetColumns)) + (horizontalInset * 2)
let windowHeight: CGFloat = measuredLineHeight() * CGFloat(targetRows)

// App branding — used in the custom About panel.
let appVersionBase = "3.01.08.04"
let appVersionSuffix = "c"
let versionSuffixColor = NSColor(calibratedRed: 1.0, green: 0.53, blue: 0.0, alpha: 1.0)   // matches the orange "c" suffix used across the swiftSUITE apps

// Per-letter colors for "swift", matching the existing swiftCORE/swiftCALENDAR branding
let letterColor_s = NSColor(calibratedRed: 0.91, green: 0.65, blue: 0.24, alpha: 1.0)   // gold
let letterColor_w = NSColor(calibratedRed: 0.88, green: 0.58, blue: 0.27, alpha: 1.0)   // orange
let letterColor_i = NSColor(calibratedRed: 0.61, green: 0.49, blue: 0.85, alpha: 1.0)   // purple
let letterColor_f = NSColor(calibratedRed: 0.32, green: 0.85, blue: 0.77, alpha: 1.0)   // teal
let letterColor_t = NSColor(calibratedRed: 0.49, green: 0.58, blue: 0.91, alpha: 1.0)   // blue

// Background/foreground color presets, selectable via the Settings window.
struct ColorTheme {
    let name: String
    let background: NSColor
    let foreground: NSColor
}
let colorThemes: [ColorTheme] = [
    // Matches macOS Terminal.app's built-in "Basic" profile — also Apple's own default.
    ColorTheme(name: "Basic", background: .white, foreground: .black),
    // Custom dark theme, not an Apple default.
    ColorTheme(name: "Clear Dark", background: NSColor(calibratedRed: 0.098039, green: 0.113725, blue: 0.152941, alpha: 1.0), foreground: .white),
    // Custom light theme, not an Apple default.
    ColorTheme(name: "Clear Light", background: .white, foreground: NSColor(calibratedRed: 0.176471, green: 0.219608, blue: 0.250980, alpha: 1.0)),
    // Matches macOS Terminal.app's built-in "Grass" profile.
    ColorTheme(name: "Grass", background: NSColor(calibratedRed: 0.074510, green: 0.466667, blue: 0.239216, alpha: 1.0), foreground: NSColor(calibratedRed: 1.0, green: 0.941176, blue: 0.647059, alpha: 1.0)),
    // Matches macOS Terminal.app's built-in "Homebrew" profile.
    ColorTheme(name: "Homebrew", background: .black, foreground: NSColor(calibratedRed: 0.156863, green: 0.996078, blue: 0.078431, alpha: 1.0)),
    // Matches macOS Terminal.app's built-in "Man Page" profile.
    ColorTheme(name: "Man Page", background: NSColor(calibratedRed: 0.996078, green: 0.956863, blue: 0.611765, alpha: 1.0), foreground: .black),
    // Matches macOS Terminal.app's built-in "Novel" profile.
    ColorTheme(name: "Novel", background: NSColor(calibratedRed: 0.874510, green: 0.858824, blue: 0.764706, alpha: 1.0), foreground: NSColor(calibratedRed: 0.231373, green: 0.137255, blue: 0.133333, alpha: 1.0)),
    // Matches macOS Terminal.app's built-in "Ocean" profile.
    ColorTheme(name: "Ocean", background: NSColor(calibratedRed: 0.231373, green: 0.396078, blue: 0.760784, alpha: 1.0), foreground: .white),
    // Matches macOS Terminal.app's built-in "Pro" profile.
    ColorTheme(name: "Pro", background: .black, foreground: NSColor(calibratedRed: 0.949020, green: 0.949020, blue: 0.949020, alpha: 1.0)),
    // Matches macOS Terminal.app's built-in "Red Sands" profile.
    ColorTheme(name: "Red Sands", background: NSColor(calibratedRed: 0.478431, green: 0.145098, blue: 0.117647, alpha: 1.0), foreground: NSColor(calibratedRed: 0.843137, green: 0.788235, blue: 0.654902, alpha: 1.0)),
    // Matches macOS Terminal.app's built-in "Silver Aerogel" profile.
    ColorTheme(name: "Silver Aerogel", background: NSColor(calibratedRed: 0.498039, green: 0.498039, blue: 0.498039, alpha: 1.0), foreground: .black)
]
// Looked up by name rather than a hardcoded index, so reordering the
// list above doesn't silently break which theme is the factory default.
let factoryDefaultThemeIndex: Int = colorThemes.firstIndex(where: { $0.name == "Clear Dark" }) ?? 0

enum CursorShape: Int, CaseIterable {
    case block = 0
    case underline = 1
    case bar = 2

    var label: String {
        switch self {
        case .block: return "Block"
        case .underline: return "Underline"
        case .bar: return "Vertical Bar"
        }
    }
}

// UserDefaults keys for persisting the chosen defaults across launches.
// These represent the SAVED default — separate from whatever's being
// live-previewed in the Settings window at any given moment.
let themeIndexDefaultsKey = "swiftCT.themeIndex"
let cursorShapeDefaultsKey = "swiftCT.cursorShape"
let cursorBlinkDefaultsKey = "swiftCT.cursorBlink"
let savedConnectionsDefaultsKey = "swiftCT.savedConnections"

// A remembered SSH connection — nickname is optional, shown alongside
// user@host in the saved-connections list.
struct SavedConnection: Codable {
    let nickname: String
    let user: String
    let host: String

    var displayName: String {
        nickname.isEmpty ? "\(user)@\(host)" : "\(nickname) (\(user)@\(host))"
    }
}

func loadSavedConnections() -> [SavedConnection] {
    guard let data = UserDefaults.standard.data(forKey: savedConnectionsDefaultsKey) else { return [] }
    return (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
}

func persistSavedConnections(_ connections: [SavedConnection]) {
    if let data = try? JSONEncoder().encode(connections) {
        UserDefaults.standard.set(data, forKey: savedConnectionsDefaultsKey)
    }
}

// ─────────────────────────────────────────────────────────────
// PATH DISCOVERY
// swiftCT is designed to live as a sibling folder alongside swiftCORE
// and the rest of the suite, inside a shared swiftSUITE root folder.
// Rather than hardcoding an absolute path, we walk upward from wherever
// this binary actually is until we find a folder containing a working
// swiftCORE binary — so the whole swiftSUITE folder can be renamed or
// moved anywhere and this still finds its neighbor correctly.
// ─────────────────────────────────────────────────────────────

func locateSwiftSuiteRoot() -> URL? {
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

func locateSwiftCorePath() -> String? {
    guard let root = locateSwiftSuiteRoot() else { return nil }
    return root.appendingPathComponent("swiftCORE/swiftCORE").path
}

// Right-click context menu for terminal views — SwiftTerm's
// LocalProcessTerminalView is a custom NSView, not an NSTextView, so it
// doesn't get Terminal.app's built-in contextual menu for free. This
// reuses the same standard Copy/Paste/Select All selectors already wired
// up on the Edit menu, routed through the normal first-responder chain
// (target: nil), so it doesn't need any new plumbing to work correctly.
func buildTerminalContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
    menu.addItem(NSMenuItem.separator())
    menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
    return menu
}

// ─────────────────────────────────────────────────────────────
// SHARED CONFIG — a plain JSON file inside swiftSUITE itself, letting
// this Settings window configure things (Syncthing API key/folder ID,
// Tailscale binary path) that swiftSYSINFO actually uses. Deliberately
// NOT UserDefaults: each compiled app has its own separate UserDefaults
// domain (different bundle IDs), so writing here wouldn't be visible to
// swiftSYSINFO at all. A shared file sidesteps that with zero extra
// entitlements needed, since neither app is sandboxed.
//
// NOTE: this file can hold a real Syncthing API key. Add its filename to
// .gitignore in any sterile/public copy of this repo.
// ─────────────────────────────────────────────────────────────

let sharedConfigFilename = "swiftsuite-config.json"

struct SharedConfig: Codable {
    var syncthingAPIKey: String?
    var syncthingFolderIDs: String?   // comma-separated — status reflects the least-caught-up folder
    var tailscaleBinaryPath: String?
    var showTailscale: Bool?          // nil defaults to true (shown) — an existing config file without this key shouldn'''t suddenly hide a row nobody asked to hide
    var showSyncthing: Bool?          // same default-to-true behavior
    var showVPN: Bool?                // same default-to-true behavior
}

func sharedConfigURL() -> URL? {
    guard let root = locateSwiftSuiteRoot() else { return nil }
    return root.appendingPathComponent("swiftCT").appendingPathComponent(sharedConfigFilename)
}

func loadSharedConfig() -> SharedConfig {
    guard let url = sharedConfigURL(), let data = try? Data(contentsOf: url) else {
        return SharedConfig()
    }
    return (try? JSONDecoder().decode(SharedConfig.self, from: data)) ?? SharedConfig()
}

func saveSharedConfig(_ config: SharedConfig) {
    guard let url = sharedConfigURL() else { return }
    if let data = try? JSONEncoder().encode(config) {
        try? data.write(to: url)
    }
}

// ─────────────────────────────────────────────────────────────
// LAUNCH SLOTS — up to 6 companion/custom apps, configurable from
// Settings, launched as fully separate processes (never windows owned
// by swiftCT — same reasoning as swiftEyes/swiftClock/System Info
// always being independent processes). Two kinds:
//
// - companion: resolved dynamically each launch via locateSwiftSuiteRoot()
//   + a folder name, so it stays portable if the whole swiftSUITE folder
//   moves or syncs to a machine with a different username.
// - custom: an absolute path to any .app, picked via a file browser.
//   Not portable across machines the same way — but there's no sensible
//   "relative" convention for something living outside swiftSUITE.
// ─────────────────────────────────────────────────────────────

let launchSlotsDefaultsKey = "swiftCT.launchSlots"
let maxLaunchSlots = 6

struct LaunchSlot: Codable {
    var kind: String   // "companion" or "custom"
    var folderName: String?
    var path: String?
    var displayName: String
}

func defaultLaunchSlots() -> [LaunchSlot] {
    guard let root = locateSwiftSuiteRoot() else { return [] }
    let companions: [(folder: String, display: String)] = [
        ("swiftEYES", "swiftEyes"),
        ("swiftCLOCK", "swiftClock"),
        ("swiftSYSINFO", "System Info")
    ]
    var slots: [LaunchSlot] = []
    for companion in companions {
        let appPath = root.appendingPathComponent("\(companion.folder)/\(companion.folder).app")
        if FileManager.default.fileExists(atPath: appPath.path) {
            slots.append(LaunchSlot(kind: "companion", folderName: companion.folder, path: nil, displayName: companion.display))
        }
    }
    return slots
}

func loadLaunchSlots() -> [LaunchSlot] {
    guard let data = UserDefaults.standard.data(forKey: launchSlotsDefaultsKey) else {
        // Never configured before — seed with whichever companion apps
        // are actually found, so it works out of the box. Persisted
        // immediately so a deliberately-emptied list later doesn't get
        // re-seeded on next launch.
        let seeded = defaultLaunchSlots()
        persistLaunchSlots(seeded)
        return seeded
    }
    return (try? JSONDecoder().decode([LaunchSlot].self, from: data)) ?? []
}

func persistLaunchSlots(_ slots: [LaunchSlot]) {
    if let data = try? JSONEncoder().encode(slots) {
        UserDefaults.standard.set(data, forKey: launchSlotsDefaultsKey)
    }
}

func launchPath(for slot: LaunchSlot) -> String? {
    switch slot.kind {
    case "companion":
        guard let folderName = slot.folderName, let root = locateSwiftSuiteRoot() else { return nil }
        return root.appendingPathComponent("\(folderName)/\(folderName).app").path
    case "custom":
        return slot.path
    default:
        return nil
    }
}

func launchSlot(_ slot: LaunchSlot) {
    guard let path = launchPath(for: slot) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [path]
    try? process.run()
}

// ─────────────────────────────────────────────────────────────
// CLI passthrough — if launched from an interactive terminal (someone
// typed `./swiftCT` directly rather than double-clicking the app),
// exec straight into swiftCORE with no GUI window at all. Behaves
// exactly like running swiftCORE itself.
// ─────────────────────────────────────────────────────────────

if isatty(STDIN_FILENO) != 0 {
    guard let corePath = locateSwiftCorePath() else {
        FileHandle.standardError.write("swiftCT: could not locate swiftCORE — is this running inside the swiftSUITE folder?\n".data(using: .utf8)!)
        exit(1)
    }
    var args: [UnsafeMutablePointer<CChar>?] = [strdup(corePath)]
    args.append(nil)
    execv(corePath, &args)
    // execv only returns on failure
    FileHandle.standardError.write("swiftCT: failed to launch swiftCORE at \(corePath)\n".data(using: .utf8)!)
    exit(1)
}

// ─────────────────────────────────────────────────────────────
// GUI mode — launched via Finder/double-click, no controlling terminal.
// ─────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────
// Remote SSH session — a completely separate window from swiftCT's
// main local swiftCORE session. Multiple of these can be open at once,
// each spawning its own `ssh` process. Deliberately kept apart from the
// local session's single-instance discipline: SSH sessions are just
// generic remote shells, with none of the "never run two swiftCORE
// processes against the same data at once" concerns that apply locally.
// ─────────────────────────────────────────────────────────────

class RemoteSessionController: NSObject, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var terminalView: LocalProcessTerminalView!
    weak var owner: AppDelegate?

    init(user: String, host: String, owner: AppDelegate) {
        self.owner = owner
        super.init()
        setupWindow(user: user, host: host)
    }

    func setupWindow(user: String, host: String) {
        let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(user)@\(host)"
        window.delegate = self
        // Without this, AppKit tries to release the window itself as
        // part of closing it, at the same time this controller's own
        // `window` property releases its reference via normal ARC
        // cleanup — two independent release paths on the same object,
        // which is exactly the double-free that was crashing deep in
        // AppKit's close-animation cleanup code.
        window.isReleasedWhenClosed = false
        // Also skip the default zoom/genie close animation entirely —
        // one less place for window lifecycle timing to race against
        // our own, and arguably more appropriate for a quick utility
        // terminal window anyway.
        window.animationBehavior = .none

        // Snapshot whatever swiftCT's main window currently looks like,
        // so new remote windows feel like part of the same app rather
        // than a jarring default-styled terminal. Not live-synced if the
        // theme changes later while this window stays open.
        let themeIndex = owner?.currentThemeIndex ?? factoryDefaultThemeIndex
        let theme = colorThemes[themeIndex]
        let bg = theme.background
        window.isOpaque = true
        window.backgroundColor = bg
        window.center()

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = bg.cgColor

        let terminalFrame = NSRect(
            x: horizontalInset, y: 0,
            width: windowWidth - (horizontalInset * 2), height: windowHeight
        )
        terminalView = LocalProcessTerminalView(frame: terminalFrame)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.processDelegate = self
        terminalView.menu = buildTerminalContextMenu()
        if let font = NSFont(name: fontName, size: fontSize) {
            terminalView.font = font
        }
        terminalView.nativeBackgroundColor = bg
        terminalView.nativeForegroundColor = theme.foreground

        container.addSubview(terminalView)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)

        terminalView.startProcess(executable: "/usr/bin/ssh", args: ["-t", "\(user)@\(host)"])
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { window.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { self.window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        // Deferred rather than synchronous: removing self from owner's
        // array here is what deallocates this very object, since that
        // array holds its only strong reference. Doing that immediately,
        // while still inside the call stack triggered by this object's
        // own window closing, risks a use-after-free if SwiftTerm's
        // internal teardown tries to touch self after this point.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.owner?.remoteSessions.removeAll { $0 === self }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, LocalProcessTerminalViewDelegate {

    var window: NSWindow!
    var terminalView: LocalProcessTerminalView!
    var container: NSView!
    var aboutWindow: NSWindow?

    // MARK: - Remote SSH session state
    var remoteSessions: [RemoteSessionController] = []
    var remoteConnectionWindow: NSWindow?
    var savedConnectionsList: [SavedConnection] = []
    var selectedSavedConnectionIndex: Int?
    var connectionsScrollView: NSScrollView?
    var nicknameField: NSTextField?
    var userField: NSTextField?
    var hostField: NSTextField?

    // MARK: - Utilities & Integrations (Settings additions)
    var utilitySlotRows: [(container: NSView, label: NSTextField, removeButton: NSButton)] = []
    var utilitiesListContainer: NSView?
    var addUtilityButton: NSButton?
    var syncthingKeyField: NSTextField?
    var syncthingFolderField: NSTextField?
    var tailscalePathField: NSTextField?
    var showTailscaleCheckbox: NSButton?
    var showSyncthingCheckbox: NSButton?
    var showVPNCheckbox: NSButton?
    var integrationsStatusLabel: NSTextField?

    // "Live" state — what's actually showing right now, including
    // temporary previews from the Settings window that haven't been
    // committed via the Default button yet.
    var currentThemeIndex = factoryDefaultThemeIndex
    var currentCursorShape: CursorShape = .block
    var currentCursorBlink: Bool = true

    // "Saved" state — what's actually persisted, i.e. what will load
    // next launch. Only changes when the Default button is pressed.
    var savedThemeIndex = factoryDefaultThemeIndex
    var savedCursorShape: CursorShape = .block
    var savedCursorBlink: Bool = true

    // MARK: - Settings window UI references
    var settingsWindow: NSWindow?
    var sidebarRows: [(container: NSView, button: NSButton)] = []
    var defaultLabel: NSTextField?
    var previewBox: NSView?
    var previewLines: [NSTextField] = []
    var cursorRadioButtons: [NSButton] = []
    var blinkCheckbox: NSButton?
    var defaultButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let corePath = locateSwiftCorePath() else {
            let alert = NSAlert()
            alert.messageText = "Could not find swiftCORE"
            alert.informativeText = "swiftCT couldn't locate a swiftCORE binary in a sibling folder. Make sure swiftCT is sitting inside the swiftSUITE folder, alongside swiftCORE."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        loadSavedDefaults()
        currentThemeIndex = savedThemeIndex
        currentCursorShape = savedCursorShape
        currentCursorBlink = savedCursorBlink

        let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "swiftCT"
        window.center()

        container = NSView(frame: frame)
        container.wantsLayer = true

        let terminalFrame = NSRect(
            x: horizontalInset,
            y: 0,
            width: windowWidth - (horizontalInset * 2),
            height: windowHeight
        )
        terminalView = LocalProcessTerminalView(frame: terminalFrame)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.processDelegate = self
        terminalView.menu = buildTerminalContextMenu()

        if let font = NSFont(name: fontName, size: fontSize) {
            terminalView.font = font
        }

        container.addSubview(terminalView)
        window.contentView = container

        applyLiveState()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupMenuBar()

        // Spawn swiftCORE as a direct local process — no SSH, no network.
        terminalView.startProcess(executable: corePath, args: [])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func loadSavedDefaults() {
        let defaults = UserDefaults.standard
        if let idx = defaults.object(forKey: themeIndexDefaultsKey) as? Int, colorThemes.indices.contains(idx) {
            savedThemeIndex = idx
        } else {
            savedThemeIndex = factoryDefaultThemeIndex
        }
        if let shapeRaw = defaults.object(forKey: cursorShapeDefaultsKey) as? Int, let shape = CursorShape(rawValue: shapeRaw) {
            savedCursorShape = shape
        }
        if let blink = defaults.object(forKey: cursorBlinkDefaultsKey) as? Bool {
            savedCursorBlink = blink
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.window.close()
        }
    }

    // MARK: - Menu bar

    func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu (next to the Apple logo)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About swiftCT",
                         action: #selector(showAboutPanel),
                         keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "Settings…",
                         action: #selector(showSettingsPanel),
                         keyEquivalent: ",")

        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "Hide swiftCT",
                         action: #selector(NSApplication.hide(_:)),
                         keyEquivalent: "h")

        let hideOthersItem = NSMenuItem(title: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit swiftCT",
                         action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")

        // Terminal menu — just the external terminal launcher now;
        // theme/transparency/cursor all moved into Settings.
        let terminalMenuItem = NSMenuItem()
        mainMenu.addItem(terminalMenuItem)
        let terminalMenu = NSMenu(title: "Terminal")
        terminalMenuItem.submenu = terminalMenu
        terminalMenu.addItem(withTitle: "Launch External Terminal",
                              action: #selector(launchExternalTerminal),
                              keyEquivalent: "")
        terminalMenu.addItem(withTitle: "New Remote Connection…",
                              action: #selector(showNewRemoteConnection),
                              keyEquivalent: "")

        // Utilities menu — up to 6 configurable apps (companion or
        // custom), each launched as a fully separate process, not a
        // window owned by swiftCT. This is deliberate: these are meant
        // to keep running as independent desktop companions even if
        // swiftCT itself quits. Same pattern already used for "Launch
        // External Terminal" above. Rebuilt dynamically from whatever's
        // configured in Settings, rather than a fixed hardcoded list.
        let utilitiesMenuItem = NSMenuItem()
        mainMenu.addItem(utilitiesMenuItem)
        let utilitiesMenu = NSMenu(title: "Utilities")
        utilitiesMenuItem.submenu = utilitiesMenu
        rebuildUtilitiesMenu(utilitiesMenu)

        // Standard Edit menu — gives you working Cmd+C / Cmd+V in the terminal
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // Rebuilds the Utilities menu's contents from the current launch
    // slots list. Called at startup, and again any time Settings adds
    // or removes a slot, so the menu bar stays in sync without needing
    // a relaunch.
    func rebuildUtilitiesMenu(_ menu: NSMenu? = nil) {
        let targetMenu: NSMenu
        if let menu = menu {
            targetMenu = menu
        } else if let existing = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Utilities" })?.submenu {
            targetMenu = existing
        } else {
            return
        }

        targetMenu.removeAllItems()
        let slots = loadLaunchSlots()
        for (index, slot) in slots.enumerated() {
            let item = NSMenuItem(title: slot.displayName, action: #selector(launchUtilitySlot(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            targetMenu.addItem(item)
        }
        if !slots.isEmpty {
            targetMenu.addItem(NSMenuItem.separator())
        }
        targetMenu.addItem(withTitle: "Manage Utilities…", action: #selector(showSettingsPanel), keyEquivalent: "")
    }

    @objc func launchUtilitySlot(_ sender: NSMenuItem) {
        let slots = loadLaunchSlots()
        guard slots.indices.contains(sender.tag) else { return }
        launchSlot(slots[sender.tag])
    }

    @objc func launchExternalTerminal() {
        guard let root = locateSwiftSuiteRoot() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", root.path]
        try? process.run()
    }

    // MARK: - New Remote Connection

    @objc func showNewRemoteConnection() {
        if remoteConnectionWindow == nil {
            buildRemoteConnectionWindow()
        }
        savedConnectionsList = loadSavedConnections()
        selectedSavedConnectionIndex = nil
        nicknameField?.stringValue = ""
        userField?.stringValue = ""
        hostField?.stringValue = ""
        refreshConnectionsList()

        remoteConnectionWindow?.center()
        remoteConnectionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildRemoteConnectionWindow() {
        let winWidth: CGFloat = 420
        let winHeight: CGFloat = 380

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: winHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "New Remote Connection"
        win.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))

        let listLabel = NSTextField(labelWithString: "Saved Connections")
        listLabel.font = NSFont.boldSystemFont(ofSize: 12)
        listLabel.frame = NSRect(x: 20, y: winHeight - 30, width: 200, height: 18)
        content.addSubview(listLabel)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: winHeight - 150, width: winWidth - 40, height: 110))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let docView = NSView(frame: NSRect(x: 0, y: 0, width: winWidth - 40 - 15, height: 1))
        scrollView.documentView = docView
        content.addSubview(scrollView)
        connectionsScrollView = scrollView

        let nickLabel = NSTextField(labelWithString: "Nickname:")
        nickLabel.frame = NSRect(x: 20, y: winHeight - 180, width: 90, height: 18)
        content.addSubview(nickLabel)
        let nickField = NSTextField(frame: NSRect(x: 116, y: winHeight - 182, width: winWidth - 136, height: 22))
        content.addSubview(nickField)
        nicknameField = nickField

        let userLabel = NSTextField(labelWithString: "User:")
        userLabel.frame = NSRect(x: 20, y: winHeight - 212, width: 90, height: 18)
        content.addSubview(userLabel)
        let uField = NSTextField(frame: NSRect(x: 116, y: winHeight - 214, width: winWidth - 136, height: 22))
        content.addSubview(uField)
        userField = uField

        let hostLabel = NSTextField(labelWithString: "Host:")
        hostLabel.frame = NSRect(x: 20, y: winHeight - 244, width: 90, height: 18)
        content.addSubview(hostLabel)
        let hField = NSTextField(frame: NSRect(x: 116, y: winHeight - 246, width: winWidth - 136, height: 22))
        content.addSubview(hField)
        hostField = hField

        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(removeSelectedConnection))
        removeBtn.frame = NSRect(x: 20, y: 16, width: 90, height: 28)
        content.addSubview(removeBtn)

        let connectBtn = NSButton(title: "Connect", target: self, action: #selector(connectToRemote))
        connectBtn.bezelStyle = .rounded
        connectBtn.keyEquivalent = "\r"
        connectBtn.frame = NSRect(x: winWidth - 110, y: 16, width: 90, height: 28)
        content.addSubview(connectBtn)

        win.contentView = content
        remoteConnectionWindow = win
    }

    func refreshConnectionsList() {
        guard let scrollView = connectionsScrollView, let docView = scrollView.documentView else { return }
        docView.subviews.forEach { $0.removeFromSuperview() }

        let rowHeight: CGFloat = 24
        let visibleHeight = scrollView.frame.height
        let contentHeight = rowHeight * CGFloat(max(savedConnectionsList.count, 1))
        let docHeight = max(contentHeight, visibleHeight)
        docView.frame = NSRect(x: 0, y: 0, width: scrollView.frame.width, height: docHeight)

        if savedConnectionsList.isEmpty {
            let empty = NSTextField(labelWithString: "No saved connections yet")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 8, y: docHeight - rowHeight, width: scrollView.frame.width - 16, height: rowHeight)
            docView.addSubview(empty)
            return
        }

        for (index, connection) in savedConnectionsList.enumerated() {
            let rowY = docHeight - CGFloat(index + 1) * rowHeight
            let button = NSButton(frame: NSRect(x: 4, y: rowY, width: scrollView.frame.width - 8, height: rowHeight))
            button.title = connection.displayName
            button.isBordered = false
            button.alignment = .left
            button.tag = index
            button.target = self
            button.action = #selector(savedConnectionRowClicked(_:))
            docView.addSubview(button)
        }
    }

    @objc func savedConnectionRowClicked(_ sender: NSButton) {
        guard savedConnectionsList.indices.contains(sender.tag) else { return }
        let connection = savedConnectionsList[sender.tag]
        selectedSavedConnectionIndex = sender.tag
        nicknameField?.stringValue = connection.nickname
        userField?.stringValue = connection.user
        hostField?.stringValue = connection.host
    }

    @objc func removeSelectedConnection() {
        guard let index = selectedSavedConnectionIndex, savedConnectionsList.indices.contains(index) else { return }
        savedConnectionsList.remove(at: index)
        persistSavedConnections(savedConnectionsList)
        selectedSavedConnectionIndex = nil
        refreshConnectionsList()
    }

    @objc func connectToRemote() {
        let nickname = nicknameField?.stringValue ?? ""
        let user = userField?.stringValue ?? ""
        let host = hostField?.stringValue ?? ""

        guard !user.isEmpty, !host.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "User and Host are required"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        if let existingIndex = savedConnectionsList.firstIndex(where: { $0.user == user && $0.host == host }) {
            savedConnectionsList[existingIndex] = SavedConnection(nickname: nickname, user: user, host: host)
        } else {
            savedConnectionsList.append(SavedConnection(nickname: nickname, user: user, host: host))
        }
        persistSavedConnections(savedConnectionsList)

        let session = RemoteSessionController(user: user, host: host, owner: self)
        remoteSessions.append(session)

        remoteConnectionWindow?.close()
    }

    // MARK: - Apply live state to the real window/terminal

    // Applies whatever the current* properties say to the actual running
    // window, container, and terminal view. Called at launch, and live as
    // you browse the Settings window (per your request — no separate
    // "preview only" mockup, the real terminal updates as you click).
    func applyLiveState() {
        let theme = colorThemes[currentThemeIndex]
        let bg = theme.background

        window.isOpaque = true
        window.backgroundColor = bg
        container.layer?.backgroundColor = bg.cgColor
        terminalView.nativeBackgroundColor = bg
        terminalView.nativeForegroundColor = theme.foreground

        applyCursorSettings()
    }

    // NOTE: unverified against an actual compile in this environment — if
    // this doesn't build, these are the first properties/enum cases to
    // check against SwiftTerm's actual Terminal/TerminalOptions API.
    func applyCursorSettings() {
        let terminal = terminalView.getTerminal()
        switch (currentCursorShape, currentCursorBlink) {
        case (.block, true):      terminal.options.cursorStyle = .blinkBlock
        case (.block, false):     terminal.options.cursorStyle = .steadyBlock
        case (.underline, true):  terminal.options.cursorStyle = .blinkUnderline
        case (.underline, false): terminal.options.cursorStyle = .steadyUnderline
        case (.bar, true):        terminal.options.cursorStyle = .blinkBar
        case (.bar, false):       terminal.options.cursorStyle = .steadyBar
        }
    }

    // MARK: - About panel

    @objc func showAboutPanel() {
        if aboutWindow == nil {
            let panelWidth: CGFloat = 340
            let panelHeight: CGFloat = 170

            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "About swiftCT"
            panel.isReleasedWhenClosed = false

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = colorThemes[currentThemeIndex].background.cgColor

            // Just the "swiftCT" wordmark uses the terminal's own font
            // (Menlo Bold), tying the logo to the actual terminal content —
            // everything else in this panel stays macOS system default.
            let titleFont = NSFont(name: "Menlo-Bold", size: 24)
                ?? NSFont(name: fontName, size: 24)
                ?? NSFont.boldSystemFont(ofSize: 24)
            let centeredStyle = NSMutableParagraphStyle()
            centeredStyle.alignment = .center

            // "swift" plain white, "CT" colored — matches swiftCORE's own
            // convention (the base word stays white, the suite-specific
            // suffix carries the color).
            let ctColor_C = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)   // yellow
            let ctColor_T = letterColor_i   // reuses swift's own purple, ties the two together

            let titleString = NSMutableAttributedString()
            titleString.append(NSAttributedString(string: "swift", attributes: [
                .font: titleFont, .foregroundColor: NSColor.white, .kern: 2.0
            ]))
            titleString.append(NSAttributedString(string: "C", attributes: [
                .font: titleFont, .foregroundColor: ctColor_C
            ]))
            titleString.append(NSAttributedString(string: "T", attributes: [
                .font: titleFont, .foregroundColor: ctColor_T
            ]))
            titleString.addAttribute(.paragraphStyle, value: centeredStyle, range: NSRange(location: 0, length: titleString.length))

            let titleField = NSTextField(labelWithAttributedString: titleString)
            titleField.frame = NSRect(x: 0, y: panelHeight - 60, width: panelWidth, height: 34)
            titleField.alignment = .center
            contentView.addSubview(titleField)

            let versionString = NSMutableAttributedString()
            versionString.append(NSAttributedString(string: "Version \(appVersionBase)", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white
            ]))
            versionString.append(NSAttributedString(string: appVersionSuffix, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: versionSuffixColor
            ]))
            versionString.addAttribute(.paragraphStyle, value: centeredStyle, range: NSRange(location: 0, length: versionString.length))
            let versionField = NSTextField(labelWithAttributedString: versionString)
            versionField.frame = NSRect(x: 0, y: panelHeight - 92, width: panelWidth, height: 20)
            versionField.alignment = .center
            contentView.addSubview(versionField)

            let descField = NSTextField(labelWithString: "swiftCT connects you to the core set of swiftSUITE\napplications — swiftCALENDAR, swiftCONTACTS,\nswiftCORE, swiftMAIL, swiftNOTES, swiftSTOCKS,\nand swiftVAULT.")
            descField.font = NSFont.systemFont(ofSize: 11)
            descField.textColor = .lightGray
            descField.alignment = .center
            descField.frame = NSRect(x: 10, y: 15, width: panelWidth - 20, height: 65)
            contentView.addSubview(descField)

            panel.contentView = contentView
            aboutWindow = panel
        }

        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings window

    @objc func showSettingsPanel() {
        if settingsWindow == nil {
            buildSettingsWindow()
        }
        // Every time Settings opens, start browsing from whatever's
        // currently live (which, if nothing's been changed since last
        // launch/commit, equals the saved default anyway).
        refreshSidebarSelection()
        refreshPreview()
        refreshCursorControls()
        updateDefaultButtonState()
        refreshUtilitySlotRows()
        let currentConfig = loadSharedConfig()
        syncthingKeyField?.stringValue = currentConfig.syncthingAPIKey ?? ""
        syncthingFolderField?.stringValue = currentConfig.syncthingFolderIDs ?? ""
        tailscalePathField?.stringValue = currentConfig.tailscaleBinaryPath ?? ""
        showTailscaleCheckbox?.state = (currentConfig.showTailscale ?? true) ? .on : .off
        showSyncthingCheckbox?.state = (currentConfig.showSyncthing ?? true) ? .on : .off
        showVPNCheckbox?.state = (currentConfig.showVPN ?? true) ? .on : .off

        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildSettingsWindow() {
        let winWidth: CGFloat = 640
        let winHeight: CGFloat = 952

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: winHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))

        // ── Sidebar ──────────────────────────────────────────────
        let sidebarWidth: CGFloat = 180
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: winHeight))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.height]
        scrollView.borderType = .noBorder

        let rowHeight: CGFloat = 44
        let contentHeight = rowHeight * CGFloat(colorThemes.count)
        // Document view is at least as tall as the visible scroll area —
        // if content is shorter than that (as it is today, with 11 fixed
        // themes), rows anchor to the top and any leftover space falls
        // below the last row instead of as a gap above the first one.
        let docHeight = max(contentHeight, winHeight)
        let docView = NSView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: docHeight))

        sidebarRows.removeAll()
        for (index, theme) in colorThemes.enumerated() {
            // Rows are laid out top-to-bottom, but AppKit's y-origin is at
            // the bottom, so row 0 (top of the list) gets the highest y.
            let rowY = docHeight - CGFloat(index + 1) * rowHeight
            let rowContainer = NSView(frame: NSRect(x: 0, y: rowY, width: sidebarWidth, height: rowHeight))
            rowContainer.wantsLayer = true

            let button = NSButton(frame: NSRect(x: 4, y: 2, width: sidebarWidth - 8, height: rowHeight - 4))
            button.title = "  " + theme.name
            button.image = makeSwatchImage(theme: theme)
            button.imagePosition = .imageLeft
            button.isBordered = false
            button.alignment = .left
            button.tag = index
            button.target = self
            button.action = #selector(sidebarRowClicked(_:))
            button.contentTintColor = .labelColor
            rowContainer.addSubview(button)

            docView.addSubview(rowContainer)
            sidebarRows.append((container: rowContainer, button: button))
        }
        scrollView.documentView = docView
        content.addSubview(scrollView)

        // "Default" sublabel, placed under whichever row is currently saved.
        let label = NSTextField(labelWithString: "Default")
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .white
        label.alignment = .center
        label.isHidden = true
        docView.addSubview(label)
        defaultLabel = label

        // ── Right side: preview + controls ──────────────────────
        let rightX = sidebarWidth + 20
        let rightWidth = winWidth - rightX - 20

        // Preview box
        let previewHeight: CGFloat = 150
        let previewY = winHeight - previewHeight - 20
        let preview = NSView(frame: NSRect(x: rightX, y: previewY, width: rightWidth, height: previewHeight))
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        content.addSubview(preview)
        previewBox = preview

        previewLines.removeAll()
        let sampleTexts = ["user@Mac swiftCT %", "swiftCORE v3.0.MM.DDc", "Ready."]
        for (i, text) in sampleTexts.enumerated() {
            let line = NSTextField(labelWithString: text)
            line.font = NSFont(name: fontName, size: 12) ?? NSFont.systemFont(ofSize: 12)
            line.frame = NSRect(x: 14, y: previewHeight - 30 - CGFloat(i * 20), width: rightWidth - 28, height: 18)
            preview.addSubview(line)
            previewLines.append(line)
        }

        // Grouped card behind Cursor — verified bounds: y=576, height=146
        // (top=722), sits just below the preview box with consistent padding.
        addSectionCard(to: content, x: rightX, y: 628, width: rightWidth, height: 146)

        // Cursor section
        let cursorLabelY: CGFloat = 744
        let cursorSectionLabel = NSTextField(labelWithString: "Cursor")
        cursorSectionLabel.font = NSFont.boldSystemFont(ofSize: 12)
        cursorSectionLabel.frame = NSRect(x: rightX, y: cursorLabelY, width: 150, height: 18)
        content.addSubview(cursorSectionLabel)

        cursorRadioButtons.removeAll()
        for (i, shape) in CursorShape.allCases.enumerated() {
            let radio = NSButton(radioButtonWithTitle: shape.label, target: self, action: #selector(cursorShapeChanged(_:)))
            radio.tag = shape.rawValue
            radio.frame = NSRect(x: rightX, y: cursorLabelY - 26 - CGFloat(i * 24), width: 200, height: 20)
            content.addSubview(radio)
            cursorRadioButtons.append(radio)
        }

        let blink = NSButton(checkboxWithTitle: "Blink cursor", target: self, action: #selector(cursorBlinkChanged(_:)))
        blink.frame = NSRect(x: rightX, y: cursorLabelY - 26 - CGFloat(CursorShape.allCases.count * 24) - 6, width: 200, height: 20)
        content.addSubview(blink)
        blinkCheckbox = blink

        // ── Utilities section ────────────────────────────────────
        let utilitiesLabelY: CGFloat = 590

        // Grouped card — verified bounds: y=348, height=220 (top=568).
        addSectionCard(to: content, x: rightX, y: 400, width: rightWidth, height: 220)

        let utilitiesLabel = NSTextField(labelWithString: "Utilities  (up to \(maxLaunchSlots))")
        utilitiesLabel.font = NSFont.boldSystemFont(ofSize: 12)
        utilitiesLabel.frame = NSRect(x: rightX, y: utilitiesLabelY, width: 250, height: 18)
        content.addSubview(utilitiesLabel)

        let utilitiesListContainer = NSView(frame: NSRect(x: rightX, y: utilitiesLabelY - 148, width: rightWidth, height: 144))
        content.addSubview(utilitiesListContainer)
        self.utilitiesListContainer = utilitiesListContainer
        refreshUtilitySlotRows()

        let addBtn = NSButton(title: "Add App…", target: self, action: #selector(addUtilityApp))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: rightX, y: utilitiesLabelY - 178, width: 110, height: 24)
        content.addSubview(addBtn)
        addUtilityButton = addBtn

        // ── Integrations section ─────────────────────────────────
        let integrationsLabelY: CGFloat = 362

        // Grouped card — verified bounds: y=70, height=270 (top=340).
        addSectionCard(to: content, x: rightX, y: 64, width: rightWidth, height: 328)

        let integrationsLabel = NSTextField(labelWithString: "Services  (for System Info)")
        integrationsLabel.font = NSFont.boldSystemFont(ofSize: 12)
        integrationsLabel.frame = NSRect(x: rightX, y: integrationsLabelY, width: 280, height: 18)
        content.addSubview(integrationsLabel)

        let existingConfig = loadSharedConfig()
        let fieldFont = NSFont.systemFont(ofSize: 11)   // matches the label size instead of defaulting to the larger system size

        let syncthingKeyLabel = NSTextField(labelWithString: "Syncthing API Key")
        syncthingKeyLabel.font = NSFont.systemFont(ofSize: 11)
        syncthingKeyLabel.frame = NSRect(x: rightX, y: integrationsLabelY - 32, width: 200, height: 14)
        content.addSubview(syncthingKeyLabel)
        let syncthingKeyField = NSTextField(frame: NSRect(x: rightX, y: integrationsLabelY - 62, width: rightWidth, height: 22))
        syncthingKeyField.font = fieldFont
        syncthingKeyField.stringValue = existingConfig.syncthingAPIKey ?? ""
        syncthingKeyField.placeholderString = "Syncthing web UI → Settings → GUI → API Key"
        content.addSubview(syncthingKeyField)
        self.syncthingKeyField = syncthingKeyField

        let syncthingFolderLabel = NSTextField(labelWithString: "Syncthing Folder ID(s) — comma-separated")
        syncthingFolderLabel.font = NSFont.systemFont(ofSize: 11)
        syncthingFolderLabel.frame = NSRect(x: rightX, y: integrationsLabelY - 94, width: 300, height: 14)
        content.addSubview(syncthingFolderLabel)
        let syncthingFolderField = NSTextField(frame: NSRect(x: rightX, y: integrationsLabelY - 124, width: rightWidth, height: 22))
        syncthingFolderField.font = fieldFont
        syncthingFolderField.stringValue = existingConfig.syncthingFolderIDs ?? ""
        syncthingFolderField.placeholderString = "abc123, def456"
        content.addSubview(syncthingFolderField)
        self.syncthingFolderField = syncthingFolderField

        let tailscalePathLabel = NSTextField(labelWithString: "Tailscale Binary Path")
        tailscalePathLabel.font = NSFont.systemFont(ofSize: 11)
        tailscalePathLabel.frame = NSRect(x: rightX, y: integrationsLabelY - 156, width: 200, height: 14)
        content.addSubview(tailscalePathLabel)
        let tailscaleFieldWidth = rightWidth - 80
        let tailscalePathField = NSTextField(frame: NSRect(x: rightX, y: integrationsLabelY - 186, width: tailscaleFieldWidth, height: 22))
        tailscalePathField.font = fieldFont
        tailscalePathField.stringValue = existingConfig.tailscaleBinaryPath ?? ""
        tailscalePathField.placeholderString = ".../Tailscale.app/Contents/MacOS/Tailscale"
        content.addSubview(tailscalePathField)
        self.tailscalePathField = tailscalePathField

        let browseTailscaleBtn = NSButton(title: "Browse…", target: self, action: #selector(browseTailscaleBinary))
        browseTailscaleBtn.bezelStyle = .rounded
        browseTailscaleBtn.frame = NSRect(x: rightX + tailscaleFieldWidth + 8, y: integrationsLabelY - 187, width: 72, height: 24)
        content.addSubview(browseTailscaleBtn)

        let showTailscaleCheckboxField = NSButton(checkboxWithTitle: "Show Tailscale row", target: nil, action: nil)
        showTailscaleCheckboxField.state = (existingConfig.showTailscale ?? true) ? .on : .off
        showTailscaleCheckboxField.frame = NSRect(x: rightX, y: integrationsLabelY - 218, width: 180, height: 20)
        content.addSubview(showTailscaleCheckboxField)
        showTailscaleCheckbox = showTailscaleCheckboxField

        let showSyncthingCheckboxField = NSButton(checkboxWithTitle: "Show Syncthing row", target: nil, action: nil)
        showSyncthingCheckboxField.state = (existingConfig.showSyncthing ?? true) ? .on : .off
        showSyncthingCheckboxField.frame = NSRect(x: rightX + 190, y: integrationsLabelY - 218, width: 180, height: 20)
        content.addSubview(showSyncthingCheckboxField)
        showSyncthingCheckbox = showSyncthingCheckboxField

        let showVPNCheckboxField = NSButton(checkboxWithTitle: "Show VPN row", target: nil, action: nil)
        showVPNCheckboxField.state = (existingConfig.showVPN ?? true) ? .on : .off
        showVPNCheckboxField.frame = NSRect(x: rightX, y: integrationsLabelY - 244, width: 180, height: 20)
        content.addSubview(showVPNCheckboxField)
        showVPNCheckbox = showVPNCheckboxField

        let saveIntegrationsBtn = NSButton(title: "Save Services", target: self, action: #selector(saveIntegrations))
        saveIntegrationsBtn.bezelStyle = .rounded
        saveIntegrationsBtn.frame = NSRect(x: rightX, y: integrationsLabelY - 286, width: 140, height: 24)
        content.addSubview(saveIntegrationsBtn)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: rightX + 150, y: integrationsLabelY - 282, width: rightWidth - 150, height: 16)
        content.addSubview(statusLabel)
        integrationsStatusLabel = statusLabel

        // Default button, bottom-right — keyEquivalent "\r" gives it the
        // native blue "primary action" styling automatically, the same
        // way every Apple dialog highlights its default button.
        let defBtn = NSButton(title: "Default", target: self, action: #selector(makeCurrentDefault))
        defBtn.bezelStyle = .rounded
        defBtn.keyEquivalent = "\r"
        defBtn.frame = NSRect(x: winWidth - 100, y: 16, width: 84, height: 28)
        content.addSubview(defBtn)
        defaultButton = defBtn

        win.contentView = content
        settingsWindow = win
    }

    // Subtle grouped-card background, the defining visual trait of modern
    // System Settings — sections sit in distinct rounded panels rather
    // than floating on one flat background. Added behind a section's own
    // controls (added to the view hierarchy first, so it renders behind).
    func addSectionCard(to content: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let card = NSView(frame: NSRect(x: x - 12, y: y, width: width + 24, height: height))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        content.addSubview(card)
    }

    func makeSwatchImage(theme: ColorTheme) -> NSImage {
        let size = NSSize(width: 36, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            theme.background.setFill()
            path.fill()
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8))
            theme.foreground.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc func sidebarRowClicked(_ sender: NSButton) {
        currentThemeIndex = sender.tag
        applyLiveState()
        refreshSidebarSelection()
        refreshPreview()
        updateDefaultButtonState()
    }

    @objc func cursorShapeChanged(_ sender: NSButton) {
        guard let shape = CursorShape(rawValue: sender.tag) else { return }
        currentCursorShape = shape
        for radio in cursorRadioButtons {
            radio.state = (radio.tag == sender.tag) ? .on : .off
        }
        applyLiveState()
        updateDefaultButtonState()
    }

    @objc func cursorBlinkChanged(_ sender: NSButton) {
        currentCursorBlink = (sender.state == .on)
        applyLiveState()
        updateDefaultButtonState()
    }

    @objc func makeCurrentDefault() {
        savedThemeIndex = currentThemeIndex
        savedCursorShape = currentCursorShape
        savedCursorBlink = currentCursorBlink

        let defaults = UserDefaults.standard
        defaults.set(savedThemeIndex, forKey: themeIndexDefaultsKey)
        defaults.set(savedCursorShape.rawValue, forKey: cursorShapeDefaultsKey)
        defaults.set(savedCursorBlink, forKey: cursorBlinkDefaultsKey)

        refreshSidebarSelection()
        updateDefaultButtonState()
    }

    // MARK: - Utilities list

    func refreshUtilitySlotRows() {
        guard let listContainer = utilitiesListContainer else { return }
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        utilitySlotRows.removeAll()

        let slots = loadLaunchSlots()
        let rowHeight: CGFloat = 24
        let containerWidth = listContainer.bounds.width

        if slots.isEmpty {
            let empty = NSTextField(labelWithString: "No utilities configured yet")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 0, y: listContainer.bounds.height - rowHeight, width: containerWidth, height: rowHeight)
            listContainer.addSubview(empty)
            return
        }

        for (index, slot) in slots.enumerated() {
            let rowY = listContainer.bounds.height - CGFloat(index + 1) * rowHeight
            let rowContainer = NSView(frame: NSRect(x: 0, y: rowY, width: containerWidth, height: rowHeight))

            let kindTag = slot.kind == "companion" ? "●" : "○"
            let label = NSTextField(labelWithString: "\(kindTag)  \(slot.displayName)")
            label.font = NSFont.systemFont(ofSize: 12)
            label.frame = NSRect(x: 4, y: 3, width: containerWidth - 34, height: 18)
            label.lineBreakMode = .byTruncatingTail
            rowContainer.addSubview(label)

            let removeBtn = NSButton(frame: NSRect(x: containerWidth - 24, y: 2, width: 18, height: 18))
            removeBtn.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")
            removeBtn.isBordered = false
            removeBtn.imagePosition = .imageOnly
            removeBtn.contentTintColor = .secondaryLabelColor
            removeBtn.target = self
            removeBtn.action = #selector(removeUtilitySlot(_:))
            removeBtn.tag = index
            rowContainer.addSubview(removeBtn)

            listContainer.addSubview(rowContainer)
            utilitySlotRows.append((container: rowContainer, label: label, removeButton: removeBtn))
        }
    }

    @objc func removeUtilitySlot(_ sender: NSButton) {
        var slots = loadLaunchSlots()
        guard slots.indices.contains(sender.tag) else { return }
        slots.remove(at: sender.tag)
        persistLaunchSlots(slots)
        refreshUtilitySlotRows()
        rebuildUtilitiesMenu()
    }

    @objc func addUtilityApp() {
        var slots = loadLaunchSlots()
        guard slots.count < maxLaunchSlots else {
            let alert = NSAlert()
            alert.messageText = "Utilities list is full"
            alert.informativeText = "Remove one before adding another — up to \(maxLaunchSlots) at a time."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Ask for a display name, defaulting to the app's own name.
        let defaultName = url.deletingPathExtension().lastPathComponent
        let nameAlert = NSAlert()
        nameAlert.messageText = "Name for this shortcut"
        nameAlert.informativeText = "Shown in the Utilities menu."
        nameAlert.addButton(withTitle: "Add")
        nameAlert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.stringValue = defaultName
        nameAlert.accessoryView = nameField
        guard nameAlert.runModal() == .alertFirstButtonReturn else { return }

        let displayName = nameField.stringValue.isEmpty ? defaultName : nameField.stringValue
        slots.append(LaunchSlot(kind: "custom", folderName: nil, path: url.path, displayName: displayName))
        persistLaunchSlots(slots)
        refreshUtilitySlotRows()
        rebuildUtilitiesMenu()
    }

    // MARK: - Integrations

    @objc func browseTailscaleBinary() {
        let panel = NSOpenPanel()
        panel.title = "Locate the Tailscale Binary"
        panel.message = "Navigate into Tailscale.app to find the actual executable (usually Contents/MacOS/Tailscale)."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Without this, NSOpenPanel treats .app bundles as one opaque
        // selectable unit rather than letting you navigate inside — but
        // the actual binary we need is nested inside the bundle.
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tailscalePathField?.stringValue = url.path
    }

    @objc func saveIntegrations() {
        var config = loadSharedConfig()
        config.syncthingAPIKey = syncthingKeyField?.stringValue
        config.syncthingFolderIDs = syncthingFolderField?.stringValue
        config.tailscaleBinaryPath = tailscalePathField?.stringValue
        config.showTailscale = (showTailscaleCheckbox?.state ?? .on) == .on
        config.showSyncthing = (showSyncthingCheckbox?.state ?? .on) == .on
        config.showVPN = (showVPNCheckbox?.state ?? .on) == .on
        saveSharedConfig(config)

        integrationsStatusLabel?.stringValue = "Saved"
        integrationsStatusLabel?.textColor = .systemGreen
        // Clear the confirmation after a moment, same low-key pattern as
        // any other transient status message.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.integrationsStatusLabel?.stringValue = ""
        }
    }

    func refreshSidebarSelection() {
        for (index, row) in sidebarRows.enumerated() {
            let isCurrent = (index == currentThemeIndex)
            row.container.layer?.backgroundColor = isCurrent
                ? NSColor.selectedContentBackgroundColor.cgColor
                : NSColor.clear.cgColor
            row.button.contentTintColor = isCurrent ? .white : .labelColor
        }
        // Position the "Default" sublabel under the saved-default row.
        if savedThemeIndex < sidebarRows.count {
            let row = sidebarRows[savedThemeIndex].container
            defaultLabel?.frame = NSRect(x: row.frame.minX, y: row.frame.minY + 2, width: row.frame.width, height: 12)
            defaultLabel?.isHidden = false
        }
    }

    func refreshPreview() {
        let theme = colorThemes[currentThemeIndex]
        previewBox?.layer?.backgroundColor = theme.background.cgColor
        for line in previewLines {
            line.textColor = theme.foreground
        }
    }

    func refreshCursorControls() {
        for radio in cursorRadioButtons {
            radio.state = (radio.tag == currentCursorShape.rawValue) ? .on : .off
        }
        blinkCheckbox?.state = currentCursorBlink ? .on : .off
    }

    func updateDefaultButtonState() {
        let matchesSaved = currentThemeIndex == savedThemeIndex
            && currentCursorShape == savedCursorShape
            && currentCursorBlink == savedCursorBlink
        defaultButton?.isEnabled = !matchesSaved
    }

    // MARK: - NSWindowDelegate

    // If the Settings window closes without the user hitting Default,
    // treat everything they were browsing as a discarded preview and
    // revert the real terminal back to the actual saved default.
    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }

        if closedWindow === settingsWindow {
            currentThemeIndex = savedThemeIndex
            currentCursorShape = savedCursorShape
            currentCursorBlink = savedCursorBlink
            applyLiveState()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()