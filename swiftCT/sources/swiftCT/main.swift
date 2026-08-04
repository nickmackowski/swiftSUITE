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
let appVersionBase = "1.0.0"
let appVersionSuffix = "c"
let versionSuffixColor = NSColor(calibratedRed: 1.0, green: 0.53, blue: 0.0, alpha: 1.0)   // matches the orange "c" suffix used across the swiftSUITE apps

// Per-letter colors for "swift", matching the existing swiftCORE/swiftCALENDAR branding
let letterColor_s = NSColor(calibratedRed: 0.91, green: 0.65, blue: 0.24, alpha: 1.0)   // gold
let letterColor_w = NSColor(calibratedRed: 0.88, green: 0.58, blue: 0.27, alpha: 1.0)   // orange
let letterColor_i = NSColor(calibratedRed: 0.61, green: 0.49, blue: 0.85, alpha: 1.0)   // purple
let letterColor_f = NSColor(calibratedRed: 0.32, green: 0.85, blue: 0.77, alpha: 1.0)   // teal
let letterColor_t = NSColor(calibratedRed: 0.49, green: 0.58, blue: 0.91, alpha: 1.0)   // blue

// Background color presets — pick via the Terminal menu at runtime.
struct ColorTheme {
    let name: String
    let background: NSColor
    let foreground: NSColor
    let alpha: CGFloat   // 1.0 = fully opaque; lower values let the desktop show through

    var backgroundWithAlpha: NSColor {
        background.withAlphaComponent(alpha)
    }
}
let colorThemes: [ColorTheme] = [
    ColorTheme(name: "Clear Dark", background: NSColor(calibratedRed: 0.098, green: 0.114, blue: 0.153, alpha: 1.0), foreground: .white, alpha: 1.0),
    ColorTheme(name: "Charcoal Gray", background: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0), foreground: .white, alpha: 1.0),
    ColorTheme(name: "Deep Navy", background: NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.14, alpha: 1.0), foreground: .white, alpha: 1.0),
    ColorTheme(name: "Dark Plum", background: NSColor(calibratedRed: 0.09, green: 0.05, blue: 0.12, alpha: 1.0), foreground: .white, alpha: 1.0),
    ColorTheme(name: "Black", background: NSColor.black, foreground: .white, alpha: 1.0),
    // Matches macOS Terminal.app's built-in "Ocean" profile, with a touch of transparency.
    ColorTheme(name: "Clear Blue", background: NSColor(calibratedRed: 0.1333333333, green: 0.3098039216, blue: 0.737254902, alpha: 1.0), foreground: .white, alpha: 0.90),
    // Matches macOS Terminal.app's built-in "Homebrew" profile, with a touch of transparency.
    ColorTheme(name: "Classic Terminal", background: NSColor.black, foreground: NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1.0), alpha: 0.90)
]
let defaultThemeIndex = 0

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

class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {

    var window: NSWindow!
    var terminalView: LocalProcessTerminalView!
    var container: NSView!
    var currentThemeIndex = defaultThemeIndex
    var themeMenuItems: [NSMenuItem] = []
    var aboutWindow: NSWindow?

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

        let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        let startTheme = colorThemes[currentThemeIndex]

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "swiftCT"
        window.isOpaque = startTheme.alpha >= 0.999
        window.backgroundColor = startTheme.backgroundWithAlpha
        window.center()

        container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = startTheme.backgroundWithAlpha.cgColor

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

        terminalView.nativeBackgroundColor = startTheme.backgroundWithAlpha
        terminalView.nativeForegroundColor = startTheme.foreground

        container.addSubview(terminalView)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupMenuBar()

        // Spawn swiftCORE as a direct local process — no SSH, no network.
        terminalView.startProcess(executable: corePath, args: [])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

        // Terminal menu — color theme picker + external terminal launcher
        let terminalMenuItem = NSMenuItem()
        mainMenu.addItem(terminalMenuItem)
        let terminalMenu = NSMenu(title: "Terminal")
        terminalMenuItem.submenu = terminalMenu

        let colorMenu = NSMenu(title: "Color Theme")
        for (index, theme) in colorThemes.enumerated() {
            let item = NSMenuItem(title: theme.name,
                                   action: #selector(changeTheme(_:)),
                                   keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = (index == currentThemeIndex) ? .on : .off
            colorMenu.addItem(item)
            themeMenuItems.append(item)
        }
        let colorMenuItem = NSMenuItem(title: "Color Theme", action: nil, keyEquivalent: "")
        colorMenuItem.submenu = colorMenu
        terminalMenu.addItem(colorMenuItem)

        terminalMenu.addItem(NSMenuItem.separator())
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

            // "swift" colored per-letter, "CT" white/bold with letter-spacing
            let titleFont = NSFont.boldSystemFont(ofSize: 24)
            let centeredStyle = NSMutableParagraphStyle()
            centeredStyle.alignment = .center

            let titleString = NSMutableAttributedString()
            let swiftLetters: [(String, NSColor)] = [
                ("s", letterColor_s),
                ("w", letterColor_w),
                ("i", letterColor_i),
                ("f", letterColor_f),
                ("t", letterColor_t)
            ]
            for (letter, color) in swiftLetters {
                titleString.append(NSAttributedString(string: letter, attributes: [
                    .font: titleFont,
                    .foregroundColor: color
                ]))
            }
            titleString.append(NSAttributedString(string: "CT", attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.white,
                .kern: 2.0
            ]))
            titleString.addAttribute(.paragraphStyle, value: centeredStyle, range: NSRange(location: 0, length: titleString.length))

            let titleField = NSTextField(labelWithAttributedString: titleString)
            titleField.frame = NSRect(x: 0, y: panelHeight - 60, width: panelWidth, height: 34)
            titleField.alignment = .center
            contentView.addSubview(titleField)

            // Version number, trailing "c" in orange
            let versionString = NSMutableAttributedString()
            versionString.append(NSAttributedString(string: "Version \(appVersionBase)", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white
            ]))
            versionString.append(NSAttributedString(string: appVersionSuffix, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: versionSuffixColor
            ]))
            versionString.addAttribute(.paragraphStyle, value: centeredStyle, range: NSRange(location: 0, length: versionString.length))
            let versionField = NSTextField(labelWithAttributedString: versionString)
            versionField.frame = NSRect(x: 0, y: panelHeight - 92, width: panelWidth, height: 20)
            versionField.alignment = .center
            contentView.addSubview(versionField)

            // Description
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

    @objc func changeTheme(_ sender: NSMenuItem) {
        let index = sender.tag
        guard colorThemes.indices.contains(index) else { return }

        currentThemeIndex = index
        let newTheme = colorThemes[index]

        window.isOpaque = newTheme.alpha >= 0.999
        window.backgroundColor = newTheme.backgroundWithAlpha
        container.layer?.backgroundColor = newTheme.backgroundWithAlpha.cgColor
        terminalView.nativeBackgroundColor = newTheme.backgroundWithAlpha
        terminalView.nativeForegroundColor = newTheme.foreground

        for item in themeMenuItems {
            item.state = (item.tag == index) ? .on : .off
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()