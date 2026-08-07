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
let windowWidth: CGFloat = 1045
let windowHeight: CGFloat = 700
let horizontalInset: CGFloat = 12
let fontSize: CGFloat = 14
let fontName = "Menlo"

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

// Tracks network byte counters at a point in time — used to compute
// throughput by diffing two samples a few seconds apart, since macOS
// has no single "current speed" value to query directly.
struct NetworkSample {
    let bytesIn: UInt64
    let bytesOut: UInt64
    let timestamp: Date
}

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
let transparencyDefaultsKey = "swiftCT.transparency"
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
let minTransparency: Double = 0.4   // slider floor — below this, text gets hard to read

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

// Small colored progress bar used in the System Info window for CPU and
// Disk usage — a rounded track with a colored fill whose width reflects
// the current percentage.
// Small rolling line graph — used for Memory's usage trend, BGInfo-style.
// Keeps a fixed-size window of recent percentage samples and redraws
// itself as a filled sparkline each time a new value comes in.
// Bidirectional network activity bar — grows blue to the right for
// upload, red to the left for download, from a centered zero point.
class NetworkBarView: NSView {
    private let track = NSView()
    private let downFill = NSView()   // red, grows left
    private let upFill = NSView()     // blue, grows right

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        track.layer?.cornerRadius = frame.height / 2
        track.frame = bounds
        track.autoresizingMask = [.width, .height]
        addSubview(track)

        downFill.wantsLayer = true
        downFill.layer?.backgroundColor = NSColor.systemRed.cgColor
        addSubview(downFill)

        upFill.wantsLayer = true
        upFill.layer?.backgroundColor = NSColor.systemBlue.cgColor
        addSubview(upFill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // maxBytesPerSecond sets full-scale bar length for each side —
    // defaults to roughly 10 Mbps, a reasonable everyday ceiling.
    // Logarithmic scale, not linear — network traffic swings across many
    // orders of magnitude (a few Kbps idle vs. 50+ Mbps active), and any
    // single linear ceiling makes either light or heavy traffic
    // effectively invisible. Log scale keeps both meaningfully visible
    // on the same bar.
    func setRates(downBytesPerSecond: Double, upBytesPerSecond: Double, maxBytesPerSecond: Double = 1_250_000) {
        let half = bounds.width / 2
        let floorBytesPerSecond: Double = 500   // ~4 Kbps — below this, treat as effectively idle

        func scaledWidth(_ bytesPerSecond: Double) -> CGFloat {
            guard bytesPerSecond > floorBytesPerSecond else {
                // Still show a faint sliver for any nonzero activity,
                // rather than a dead-flat bar during light traffic.
                return bytesPerSecond > 0 ? half * 0.04 : 0
            }
            let logValue = log10(bytesPerSecond)
            let logMin = log10(floorBytesPerSecond)
            let logMax = log10(maxBytesPerSecond)
            let fraction = (logValue - logMin) / (logMax - logMin)
            return half * CGFloat(max(0, min(1, fraction)))
        }

        let downWidth = scaledWidth(downBytesPerSecond)
        let upWidth = scaledWidth(upBytesPerSecond)
        downFill.frame = NSRect(x: half - downWidth, y: 0, width: downWidth, height: bounds.height)
        upFill.frame = NSRect(x: half, y: 0, width: upWidth, height: bounds.height)
    }
}

class SparklineView: NSView {
    var values: [Double] = []
    let maxPoints = 30
    var lineColor: NSColor = .systemBlue
    var fixedMax: CGFloat = 100   // memory is a 0–100% metric, so scale is fixed rather than dynamic

    func addValue(_ value: Double) {
        values.append(value)
        if values.count > maxPoints { values.removeFirst() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard values.count > 1 else { return }

        let stepX = bounds.width / CGFloat(maxPoints - 1)
        let linePath = NSBezierPath()
        let fillPath = NSBezierPath()

        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * stepX
            let y = bounds.height * CGFloat(min(value, Double(fixedMax)) / Double(fixedMax))
            let point = NSPoint(x: x, y: y)
            if index == 0 {
                linePath.move(to: point)
                fillPath.move(to: NSPoint(x: x, y: 0))
                fillPath.line(to: point)
            } else {
                linePath.line(to: point)
                fillPath.line(to: point)
            }
        }
        let lastX = CGFloat(values.count - 1) * stepX
        fillPath.line(to: NSPoint(x: lastX, y: 0))
        fillPath.close()

        lineColor.withAlphaComponent(0.2).setFill()
        fillPath.fill()
        lineColor.setStroke()
        linePath.lineWidth = 1.5
        linePath.stroke()
    }
}

// Which visual indicator (if any) a telemetry row gets, beyond its text value.
enum RowVisual: Equatable {
    case none
    case percentBar
    case sparkline
    case networkBar
}

class PercentBar: NSView {
    private let track = NSView()
    private let fill = NSView()
    var barColor: NSColor = .systemBlue {
        didSet { fill.layer?.backgroundColor = barColor.cgColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        track.layer?.cornerRadius = frame.height / 2
        track.frame = bounds
        track.autoresizingMask = [.width, .height]
        addSubview(track)

        fill.wantsLayer = true
        fill.layer?.backgroundColor = barColor.cgColor
        fill.layer?.cornerRadius = frame.height / 2
        fill.frame = NSRect(x: 0, y: 0, width: 0, height: frame.height)
        addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setPercent(_ percent: Double) {
        let clamped = max(0, min(100, percent))
        let width = bounds.width * CGFloat(clamped / 100)
        fill.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}

// Picks a bar color by severity, BGInfo-style — green/orange/red.
func severityColor(for percent: Double) -> NSColor {
    if percent < 60 { return .systemGreen }
    if percent < 85 { return .systemOrange }
    return .systemRed
}

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
        let transparency = owner?.currentTransparency ?? 1.0
        let bg = theme.background.withAlphaComponent(transparency)
        window.isOpaque = transparency >= 0.999
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

    // MARK: - Telemetry window state
    var telemetryWindow: NSWindow?
    var telemetryTimer: Timer?
    var telemetryLabels: [String: NSTextField] = [:]
    var telemetryBars: [String: PercentBar] = [:]
    var telemetryGraphs: [String: SparklineView] = [:]
    var telemetryNetworkBars: [String: NetworkBarView] = [:]
    var lastNetworkSample: NetworkSample?

    // MARK: - Remote SSH session state
    var remoteSessions: [RemoteSessionController] = []
    var remoteConnectionWindow: NSWindow?
    var savedConnectionsList: [SavedConnection] = []
    var selectedSavedConnectionIndex: Int?
    var connectionsScrollView: NSScrollView?
    var nicknameField: NSTextField?
    var userField: NSTextField?
    var hostField: NSTextField?

    // "Live" state — what's actually showing right now, including
    // temporary previews from the Settings window that haven't been
    // committed via the Default button yet.
    var currentThemeIndex = factoryDefaultThemeIndex
    var currentTransparency: CGFloat = 1.0
    var currentCursorShape: CursorShape = .block
    var currentCursorBlink: Bool = true

    // "Saved" state — what's actually persisted, i.e. what will load
    // next launch. Only changes when the Default button is pressed.
    var savedThemeIndex = factoryDefaultThemeIndex
    var savedTransparency: CGFloat = 1.0
    var savedCursorShape: CursorShape = .block
    var savedCursorBlink: Bool = true

    // MARK: - Settings window UI references
    var settingsWindow: NSWindow?
    var sidebarRows: [(container: NSView, button: NSButton)] = []
    var defaultLabel: NSTextField?
    var previewBox: NSView?
    var previewLines: [NSTextField] = []
    var settingsTransparencySlider: NSSlider?
    var transparencyValueLabel: NSTextField?
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
        currentTransparency = savedTransparency
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
        if let t = defaults.object(forKey: transparencyDefaultsKey) as? Double {
            savedTransparency = CGFloat(t)
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
        terminalMenu.addItem(withTitle: "System Info…",
                              action: #selector(showTelemetryPanel),
                              keyEquivalent: "")

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

    @objc func launchExternalTerminal() {
        guard let root = locateSwiftSuiteRoot() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", root.path]
        try? process.run()
    }

    // MARK: - Telemetry (System Info) window

    @objc func showTelemetryPanel() {
        if telemetryWindow == nil {
            buildTelemetryWindow()
        }
        telemetryWindow?.center()
        telemetryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTelemetryRefresh()
    }

    func buildTelemetryWindow() {
        let winWidth: CGFloat = 300
        let plainRowHeight: CGFloat = 30      // single-line rows: icon, label, value all together
        let visualRowHeight: CGFloat = 50     // rows with a bar/graph: icon+label on top, bar/graph below, value under that

        let (systemName, osVersion) = systemNameAndOS()
        let extraLocalVolumes = mountedExtraLocalVolumes()
        let networkVolumes = mountedNetworkVolumes()

        let magentaColor = NSColor(calibratedRed: 0.93, green: 0.25, blue: 0.60, alpha: 1.0)

        // NOTE: SF Symbol names below are my best recollection, not
        // verified against Apple's actual catalog from this sandbox — if
        // an icon shows up blank, that's the first thing to check/swap
        // (search for alternatives in the Xcode SF Symbols app).
        var rows: [(title: String, key: String, symbol: String, visual: RowVisual, barColor: NSColor)] = [
            ("System", "system", "desktopcomputer", .none, .clear),
            ("OS Version", "os", "gearshape", .none, .clear),
            ("Uptime", "uptime", "clock", .none, .clear),
            ("CPU", "cpu", "cpu", .percentBar, letterColor_f),
            ("Memory", "memory", "memorychip", .percentBar, .systemGreen),
            ("Disk", "disk", "internaldrive", .percentBar, letterColor_s)
        ]
        // USB drives (purple) and iSCSI/other non-removable local volumes
        // (gold, matching the boot disk) — right after Disk.
        for (index, volume) in extraLocalVolumes.enumerated() {
            let color = volume.isRemovable ? letterColor_i : letterColor_s
            let symbol = volume.isRemovable ? "externaldrive" : "internaldrive"
            rows.append((volume.name, "localvol\(index)", symbol, .percentBar, color))
        }
        // Network shares (magenta), one per mounted share, computed once
        // at window-build time (see mountedNetworkVolumes() comment).
        for (index, volume) in networkVolumes.enumerated() {
            rows.append((volume.name, "netvol\(index)", "externaldrive.connected.to.line.below", .percentBar, magentaColor))
        }
        rows.append(("Network", "network", "network", .networkBar, .clear))

        let totalRowsHeight = rows.reduce(CGFloat(0)) { sum, row in
            sum + (row.visual == .none ? plainRowHeight : visualRowHeight)
        }
        let winHeight: CGFloat = 30 + totalRowsHeight

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: winHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "System Info"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let theme = colorThemes[currentThemeIndex]
        let bg = theme.background.withAlphaComponent(currentTransparency)
        win.isOpaque = currentTransparency >= 0.999
        win.backgroundColor = bg

        let content = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = bg.cgColor

        var y = winHeight - 20
        for row in rows {
            let rowHeight = (row.visual == .none) ? plainRowHeight : visualRowHeight

            if row.visual == .none {
                // Single line: icon, label, value all together.
                let icon = NSImageView(frame: NSRect(x: 16, y: y - 14, width: 16, height: 16))
                icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.title)
                icon.contentTintColor = theme.foreground
                content.addSubview(icon)

                let label = NSTextField(labelWithString: row.title)
                label.font = NSFont.boldSystemFont(ofSize: 11)
                label.textColor = theme.foreground
                label.frame = NSRect(x: 38, y: y - 12, width: 110, height: 14)
                content.addSubview(label)

                let value = NSTextField(labelWithString: "—")
                value.font = NSFont.systemFont(ofSize: 11)
                value.textColor = theme.foreground
                value.lineBreakMode = .byTruncatingTail
                value.alignment = .right
                value.frame = NSRect(x: winWidth - 148, y: y - 12, width: 132, height: 14)
                content.addSubview(value)
                telemetryLabels[row.key] = value
            } else {
                // Icon + label on top, bar/graph below, value text under that.
                let icon = NSImageView(frame: NSRect(x: 16, y: y - 14, width: 16, height: 16))
                icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.title)
                icon.contentTintColor = theme.foreground
                content.addSubview(icon)

                let label = NSTextField(labelWithString: row.title)
                label.font = NSFont.boldSystemFont(ofSize: 11)
                label.textColor = theme.foreground
                label.frame = NSRect(x: 38, y: y - 12, width: 150, height: 14)
                content.addSubview(label)

                switch row.visual {
                case .percentBar:
                    let bar = PercentBar(frame: NSRect(x: 16, y: y - 28, width: winWidth - 32, height: 6))
                    bar.barColor = row.barColor
                    content.addSubview(bar)
                    telemetryBars[row.key] = bar
                case .sparkline:
                    let graph = SparklineView(frame: NSRect(x: 16, y: y - 32, width: winWidth - 32, height: 14))
                    graph.lineColor = row.barColor
                    content.addSubview(graph)
                    telemetryGraphs[row.key] = graph
                case .networkBar:
                    let bar = NetworkBarView(frame: NSRect(x: 16, y: y - 28, width: winWidth - 32, height: 6))
                    content.addSubview(bar)
                    telemetryNetworkBars[row.key] = bar
                case .none:
                    break
                }

                let value = NSTextField(labelWithString: "—")
                value.font = NSFont.systemFont(ofSize: 10)
                value.textColor = theme.foreground.withAlphaComponent(0.75)
                value.alignment = .center
                value.frame = NSRect(x: 16, y: y - 46, width: winWidth - 32, height: 12)
                content.addSubview(value)
                telemetryLabels[row.key] = value
            }

            y -= rowHeight
        }

        // System, OS, and volume info don't change during a session, so
        // populate them once here rather than re-fetching every refresh tick.
        telemetryLabels["system"]?.stringValue = systemName
        telemetryLabels["os"]?.stringValue = osVersion
        for (index, volume) in extraLocalVolumes.enumerated() {
            telemetryLabels["localvol\(index)"]?.stringValue = volume.valueText
            if let percent = volume.usedPercent {
                telemetryBars["localvol\(index)"]?.setPercent(percent)
            }
        }
        for (index, volume) in networkVolumes.enumerated() {
            telemetryLabels["netvol\(index)"]?.stringValue = volume.valueText
            if let percent = volume.usedPercent {
                telemetryBars["netvol\(index)"]?.setPercent(percent)
            }
        }

        win.contentView = content
        telemetryWindow = win
    }

    func startTelemetryRefresh() {
        refreshTelemetry()   // immediate first update, don't wait for the first tick
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshTelemetry()
        }
    }

    func stopTelemetryRefresh() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }

    func refreshTelemetry() {
        // Fetching CPU/memory/network involves spawning processes and
        // waiting on them — doing that on a background queue keeps the
        // UI from hitching on every refresh tick.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let (cpuRawText, cpuPercent) = self.fetchTopSummary()
            let cpuText = cpuPercent.map { "\(Int($0))% used" } ?? cpuRawText
            let (memoryPercent, memoryText) = self.fetchMemoryInfo()
            let uptime = self.formattedUptime()
            let (diskText, diskPercent) = self.diskSpaceInfo()

            var networkText = "Calculating…"
            var downRate: Double = 0
            var upRate: Double = 0
            if let sample = self.fetchNetworkCounters() {
                if let rates = self.networkRates(previous: self.lastNetworkSample, current: sample) {
                    networkText = rates.text
                    downRate = rates.downBytesPerSecond
                    upRate = rates.upBytesPerSecond
                }
                self.lastNetworkSample = sample
            } else {
                networkText = "Unavailable"
            }

            DispatchQueue.main.async {
                self.telemetryLabels["cpu"]?.stringValue = cpuText
                self.telemetryLabels["memory"]?.stringValue = memoryText
                self.telemetryLabels["uptime"]?.stringValue = uptime
                self.telemetryLabels["disk"]?.stringValue = diskText
                self.telemetryLabels["network"]?.stringValue = networkText

                if let cpuPercent = cpuPercent {
                    self.telemetryBars["cpu"]?.setPercent(cpuPercent)
                }
                if let diskPercent = diskPercent {
                    self.telemetryBars["disk"]?.setPercent(diskPercent)
                }
                if let memoryPercent = memoryPercent {
                    self.telemetryBars["memory"]?.setPercent(memoryPercent)
                }
                self.telemetryNetworkBars["network"]?.setRates(downBytesPerSecond: downRate, upBytesPerSecond: upRate)
            }
        }
    }

    // MARK: - Individual stat fetchers

    func formattedUptime() -> String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    func diskSpaceInfo() -> (text: String, usedPercent: Double?) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let availableBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            let totalBytes = Int64(values.volumeTotalCapacity ?? 0)
            let availableGB = Double(availableBytes) / 1_000_000_000
            let totalGB = Double(totalBytes) / 1_000_000_000
            let usedGB = totalGB - availableGB
            let text = String(format: "%.0f / %.0f GB used", usedGB, totalGB)
            var usedPercent: Double? = nil
            if totalGB > 0 {
                usedPercent = (usedGB / totalGB) * 100
            }
            return (text, usedPercent)
        } catch {
            return ("Unavailable", nil)
        }
    }

    // vm_stat gives clean page counts rather than top's summary text,
    // making it a more reliable source for an actual numeric percentage
    // (needed to drive the memory graph). This approximates what
    // Activity Monitor shows (active + wired + compressed pages / total
    // physical memory) — a reasonable estimate, not guaranteed to match
    // Activity Monitor's own number to the decimal, since macOS memory
    // accounting has genuine nuance around what counts as "used."
    func fetchMemoryInfo() -> (percent: Double?, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        func extractNumber(from line: Substring) -> Double {
            guard let colonIndex = line.firstIndex(of: ":") else { return 0 }
            let after = line[line.index(after: colonIndex)...]
            let trimmed = after.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return Double(trimmed) ?? 0
        }

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return (nil, "Unavailable") }

            var pageSize: Double = 16384   // Apple Silicon default; overwritten below if the header specifies otherwise
            var pagesActive: Double = 0
            var pagesWired: Double = 0
            var pagesCompressed: Double = 0

            for line in output.split(separator: "\n") {
                if line.contains("page size of"), let range = line.range(of: "page size of "), let endRange = line.range(of: " bytes") {
                    pageSize = Double(line[range.upperBound..<endRange.lowerBound]) ?? pageSize
                } else if line.hasPrefix("Pages active:") {
                    pagesActive = extractNumber(from: line)
                } else if line.hasPrefix("Pages wired down:") {
                    pagesWired = extractNumber(from: line)
                } else if line.hasPrefix("Pages occupied by compressor:") {
                    pagesCompressed = extractNumber(from: line)
                }
            }

            let usedBytes = (pagesActive + pagesWired + pagesCompressed) * pageSize
            let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
            guard totalBytes > 0 else { return (nil, "Unavailable") }

            let usedGB = usedBytes / 1_000_000_000
            let totalGB = totalBytes / 1_000_000_000
            let text = String(format: "%.0f / %.0f GB used", usedGB, totalGB)
            return ((usedBytes / totalBytes) * 100, text)
        } catch {
            return (nil, "Unavailable")
        }
    }

    // Network-mounted volumes (SMB/AFP/NFS shares) — computed once when
    // the System Info window opens, not re-checked on every refresh
    // tick. A drive mounted/unmounted after opening won't add or remove
    // a row until the window's reopened — full live row insertion is a
    // bigger UI change than seemed worth it for this pass.
    // Additional LOCAL volumes beyond the boot disk — USB drives (shown
    // purple) and iSCSI or other non-removable local block storage
    // (shown the same gold as the main boot disk, since iSCSI presents
    // to macOS as ordinary local storage despite being network-attached
    // at the protocol level).
    func mountedExtraLocalVolumes() -> [(name: String, valueText: String, usedPercent: Double?, isRemovable: Bool)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }

        var results: [(name: String, valueText: String, usedPercent: Double?, isRemovable: Bool)] = []
        for url in urls {
            guard url.path != "/" else { continue }   // boot volume already shown as "Disk"
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.volumeIsLocal == true else { continue }   // network volumes handled separately

            let name = values.volumeName ?? url.lastPathComponent
            let isRemovable = values.volumeIsRemovable ?? false

            if let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 {
                let availableGB = Double(available) / 1_000_000_000
                let totalGB = Double(total) / 1_000_000_000
                let usedGB = totalGB - availableGB
                let text = "\(String(format: "%.0f", usedGB)) / \(String(format: "%.0f", totalGB)) GB used"
                let percent = (usedGB / totalGB) * 100
                results.append((name, text, percent, isRemovable))
            } else {
                results.append((name, "—", nil, isRemovable))
            }
        }
        return results
    }

    func mountedNetworkVolumes() -> [(name: String, valueText: String, usedPercent: Double?)] {
        // .volumeAvailableCapacityForImportantUsageKey is a heuristic
        // tuned for local/internal storage decisions (Time Machine,
        // purgeable space) and doesn't reliably report anything
        // meaningful for network shares — it was coming back essentially
        // empty, making every share look 100% full. The plain
        // .volumeAvailableCapacityKey is the older, more broadly
        // supported key and reports real numbers across network
        // filesystems too.
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }

        var results: [(name: String, valueText: String, usedPercent: Double?)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.volumeIsLocal == false else { continue }   // only network volumes

            let name = values.volumeName ?? url.lastPathComponent
            if let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 {
                let availableGB = Double(available) / 1_000_000_000
                let totalGB = Double(total) / 1_000_000_000
                let usedGB = totalGB - availableGB
                let text = "\(String(format: "%.0f", usedGB)) / \(String(format: "%.0f", totalGB)) GB used"
                let percent = (usedGB / totalGB) * 100
                results.append((name, text, percent))
            } else {
                results.append((name, "—", nil))
            }
        }
        return results
    }

    func systemNameAndOS() -> (name: String, os: String) {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return (name, osString)
    }

    func fetchTopSummary() -> (cpu: String, cpuPercent: Double?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "1", "-n", "0"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()   // discard stderr noise

        var cpuResult = "Unavailable"

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                    if line.hasPrefix("CPU usage:") {
                        cpuResult = line.replacingOccurrences(of: "CPU usage: ", with: "")
                    }
                }
            }
        } catch {
            // leave defaults
        }

        // Parse "X% idle" out of the CPU line to compute used% (100 - idle).
        var cpuPercent: Double? = nil
        if let idleRange = cpuResult.range(of: "% idle") {
            let before = cpuResult[..<idleRange.lowerBound]
            let numberText = before.split(separator: " ").last ?? ""
            if let idleValue = Double(numberText) {
                cpuPercent = 100 - idleValue
            }
        }

        return (cpuResult, cpuPercent)
    }

    // NOTE: parses `netstat -ib`'s column output, targeting the "en0"
    // interface specifically (the common primary interface on both
    // WiFi-based laptops and wired Mac Pros). If network stats never
    // populate on a given machine, run `netstat -ib` directly and check
    // whether the active interface is actually named something else —
    // that name is the one thing to change below.
    let networkInterfaceName = "en0"

    func fetchNetworkCounters() -> NetworkSample? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ib"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count >= 10, columns[0] == Substring(networkInterfaceName) else { continue }
                if let ibytes = UInt64(columns[6]), let obytes = UInt64(columns[9]) {
                    return NetworkSample(bytesIn: ibytes, bytesOut: obytes, timestamp: Date())
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    func networkRates(previous: NetworkSample?, current: NetworkSample) -> (text: String, downBytesPerSecond: Double, upBytesPerSecond: Double)? {
        guard let previous = previous else { return nil }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return nil }

        // Wrapping subtraction as a defensive measure in case a counter
        // resets between samples (shouldn't happen in a normal short
        // interval, but costs nothing to guard against).
        let inRate = Double(current.bytesIn &- previous.bytesIn) / elapsed
        let outRate = Double(current.bytesOut &- previous.bytesOut) / elapsed

        func formatRate(_ bytesPerSecond: Double) -> String {
            let kbps = bytesPerSecond * 8 / 1000
            if kbps > 1000 {
                return String(format: "%.1f Mbps", kbps / 1000)
            }
            return String(format: "%.0f Kbps", kbps)
        }

        let text = "↓ \(formatRate(inRate))  ↑ \(formatRate(outRate))"
        return (text, inRate, outRate)
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
        let bg = theme.background.withAlphaComponent(currentTransparency)

        window.isOpaque = currentTransparency >= 0.999
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
        settingsTransparencySlider?.doubleValue = Double(currentTransparency)
        transparencyValueLabel?.stringValue = "\(Int(currentTransparency * 100))%"
        updateDefaultButtonState()

        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildSettingsWindow() {
        let winWidth: CGFloat = 640
        let winHeight: CGFloat = 560

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

        // Transparency slider
        let transLabel = NSTextField(labelWithString: "Transparency")
        transLabel.font = NSFont.systemFont(ofSize: 12)
        transLabel.frame = NSRect(x: rightX, y: previewY - 30, width: 100, height: 18)
        content.addSubview(transLabel)

        let sliderWidth = rightWidth - 105 - 55   // leave room for the percentage box
        let slider = NSSlider(value: Double(currentTransparency),
                               minValue: minTransparency,
                               maxValue: 1.0,
                               target: self,
                               action: #selector(settingsTransparencyChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: rightX + 105, y: previewY - 32, width: sliderWidth, height: 20)
        content.addSubview(slider)
        settingsTransparencySlider = slider

        let percentLabel = NSTextField(labelWithString: "\(Int(currentTransparency * 100))%")
        percentLabel.font = NSFont.systemFont(ofSize: 12)
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: rightX + 105 + sliderWidth + 8, y: previewY - 30, width: 42, height: 18)
        content.addSubview(percentLabel)
        transparencyValueLabel = percentLabel

        // Cursor section
        let cursorLabelY = previewY - 65
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

        // Default button, bottom-right
        let defBtn = NSButton(title: "Default", target: self, action: #selector(makeCurrentDefault))
        defBtn.bezelStyle = .rounded
        defBtn.frame = NSRect(x: winWidth - 100, y: 16, width: 84, height: 28)
        content.addSubview(defBtn)
        defaultButton = defBtn

        win.contentView = content
        settingsWindow = win
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

    @objc func settingsTransparencyChanged(_ sender: NSSlider) {
        currentTransparency = CGFloat(sender.doubleValue)
        transparencyValueLabel?.stringValue = "\(Int(currentTransparency * 100))%"
        applyLiveState()
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
        savedTransparency = currentTransparency
        savedCursorShape = currentCursorShape
        savedCursorBlink = currentCursorBlink

        let defaults = UserDefaults.standard
        defaults.set(savedThemeIndex, forKey: themeIndexDefaultsKey)
        defaults.set(Double(savedTransparency), forKey: transparencyDefaultsKey)
        defaults.set(savedCursorShape.rawValue, forKey: cursorShapeDefaultsKey)
        defaults.set(savedCursorBlink, forKey: cursorBlinkDefaultsKey)

        refreshSidebarSelection()
        updateDefaultButtonState()
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
        let bg = theme.background.withAlphaComponent(currentTransparency)
        previewBox?.layer?.backgroundColor = bg.cgColor
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
            && currentTransparency == savedTransparency
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
            currentTransparency = savedTransparency
            currentCursorShape = savedCursorShape
            currentCursorBlink = savedCursorBlink
            applyLiveState()
        } else if closedWindow === telemetryWindow {
            stopTelemetryRefresh()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()