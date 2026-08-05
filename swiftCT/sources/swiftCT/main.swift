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

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, LocalProcessTerminalViewDelegate {

    var window: NSWindow!
    var terminalView: LocalProcessTerminalView!
    var container: NSView!
    var aboutWindow: NSWindow?

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
        let docHeight = rowHeight * CGFloat(colorThemes.count)
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
        let sampleTexts = ["jzmfcz@MacPro swiftCT %", "swiftCORE v3.0.MM.DDc", "Ready."]
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

        let slider = NSSlider(value: Double(currentTransparency),
                               minValue: minTransparency,
                               maxValue: 1.0,
                               target: self,
                               action: #selector(settingsTransparencyChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: rightX + 105, y: previewY - 32, width: rightWidth - 105, height: 20)
        content.addSubview(slider)
        settingsTransparencySlider = slider

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
        guard let closedWindow = notification.object as? NSWindow, closedWindow === settingsWindow else { return }

        currentThemeIndex = savedThemeIndex
        currentTransparency = savedTransparency
        currentCursorShape = savedCursorShape
        currentCursorBlink = savedCursorBlink
        applyLiveState()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()