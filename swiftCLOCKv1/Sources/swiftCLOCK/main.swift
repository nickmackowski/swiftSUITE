// ═══════════════════════════════════════════════════════════════
// APP: swiftCLOCKv1
// The original design — a flat, minimal analog clock companion app
// File: Sources/swiftCLOCKv1/main.swift
// Updated: 2026-08-11
// ═══════════════════════════════════════════════════════════════

import Cocoa

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

// Falls back to 1.0 (fully opaque, today's existing look) if swiftCT isn't installed
// alongside this app, hasn't been launched yet, or has never had its opacity saved.
private func loadSharedTerminalOpacity() -> CGFloat {
    guard let root = locateSwiftSuiteRoot() else { return 1.0 }
    let url = root.appendingPathComponent("swiftCT").appendingPathComponent("swiftsuite-config.json")
    guard let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(SharedTerminalConfig.self, from: data),
          let opacity = config.terminalOpacity else {
        return 1.0
    }
    return CGFloat(opacity)
}

// MARK: - ClockFaceView
// A flat, minimal GtkClock-style analog face: soft light-grey dial, dot markers
// with bold dots at each hour, a short thick hour wedge, a long thin minute hand,
// a red second hand, and the date shown as plain text above the 6 o'clock position.

final class ClockFaceView: NSView {

    // Colors sourced from swiftCT: pure white / dark charcoal-grey for light mode
    // (screenshot reference), and swiftCT's "Clear Dark" theme (its default) for the reversed mode.
    private let lightDialColor = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)          // #FFFFFF
    private let lightMarkColor = NSColor(calibratedRed: 89.0/255, green: 89.0/255, blue: 89.0/255, alpha: 1.0)  // #595959
    private let darkDialColor = NSColor(calibratedRed: 0.098039, green: 0.113725, blue: 0.152941, alpha: 1.0)   // swiftCT "Clear Dark" background
    private let darkMarkColor = NSColor.white                                                                    // swiftCT "Clear Dark" foreground

    private let secondHandColor = NSColor.systemRed // stays red in both modes, matches the icon's red dot
    private let hourHandColor = NSColor(calibratedRed: 145.0/255, green: 170.0/255, blue: 255.0/255, alpha: 1.0)   // blue, matches the icon's blue dot
    private let minuteHandColor = NSColor(calibratedRed: 52.0/255, green: 199.0/255, blue: 89.0/255, alpha: 1.0)   // green, matches the icon's green dot + System Info's Memory bar

    var isDarkMode = true {   // defaults to dark, matching swiftCT and swiftSYSINFO's own default theme
        didSet { needsDisplay = true }
    }

    // Read once at launch (set by AppDelegate right after init) rather than re-reading the
    // shared file on every draw — swiftCT's opacity isn't going to change while this app is
    // already running, so there's no need to poll it continuously.
    var sharedDarkModeOpacity: CGFloat = 1.0

    private var dialColor: NSColor {
        isDarkMode ? darkDialColor.withAlphaComponent(sharedDarkModeOpacity) : lightDialColor
    }
    private var markColor: NSColor { isDarkMode ? darkMarkColor : lightMarkColor }
    private var minorDotColor: NSColor { markColor.withAlphaComponent(0.35) }

    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // Border / resize handle tuning
    private let edgeGrabMargin: CGFloat = 8
    private let borderInset: CGFloat = 1.5
    private var isHovering = false

    private struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let left   = ResizeEdges(rawValue: 1 << 0)
        static let right  = ResizeEdges(rawValue: 1 << 1)
        static let top    = ResizeEdges(rawValue: 1 << 2)
        static let bottom = ResizeEdges(rawValue: 1 << 3)
    }
    private var activeResizeEdges: ResizeEdges = []
    private var dragStartMouseScreen: NSPoint = .zero
    private var dragStartWindowFrame: NSRect = .zero

    var minWindowSize = NSSize(width: 100, height: 100)
    var maxWindowSize = NSSize(width: 900, height: 900)

    override var isFlipped: Bool { false }

    // MARK: Tracking / hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorForEdges(edges(at: point)).set()
    }

    // MARK: Edge detection / resize cursors

    private func edges(at point: NSPoint) -> ResizeEdges {
        var edges: ResizeEdges = []
        if point.x <= edgeGrabMargin { edges.insert(.left) }
        if point.x >= bounds.width - edgeGrabMargin { edges.insert(.right) }
        if point.y <= edgeGrabMargin { edges.insert(.bottom) }
        if point.y >= bounds.height - edgeGrabMargin { edges.insert(.top) }
        return edges
    }

    private func cursorForEdges(_ edges: ResizeEdges) -> NSCursor {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        if horizontal && vertical { return .crosshair }
        if horizontal { return .resizeLeftRight }
        if vertical { return .resizeUpDown }
        return .arrow
    }

    // MARK: Mouse down / drag / up — border resize, interior drag moves the window

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = edges(at: point)

        guard !edges.isEmpty, let window = self.window else {
            super.mouseDown(with: event) // interior click — let the window handle background dragging
            return
        }

        activeResizeEdges = edges
        dragStartMouseScreen = NSEvent.mouseLocation
        dragStartWindowFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeResizeEdges.isEmpty, let window = self.window else {
            super.mouseDragged(with: event)
            return
        }

        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouseScreen.x
        let dy = current.y - dragStartMouseScreen.y

        var frame = dragStartWindowFrame

        if activeResizeEdges.contains(.right) {
            frame.size.width = max(minWindowSize.width, min(maxWindowSize.width, dragStartWindowFrame.width + dx))
        }
        if activeResizeEdges.contains(.left) {
            let newWidth = max(minWindowSize.width, min(maxWindowSize.width, dragStartWindowFrame.width - dx))
            frame.origin.x = dragStartWindowFrame.maxX - newWidth
            frame.size.width = newWidth
        }
        if activeResizeEdges.contains(.top) {
            frame.size.height = max(minWindowSize.height, min(maxWindowSize.height, dragStartWindowFrame.height + dy))
        }
        if activeResizeEdges.contains(.bottom) {
            let newHeight = max(minWindowSize.height, min(maxWindowSize.height, dragStartWindowFrame.height - dy))
            frame.origin.y = dragStartWindowFrame.maxY - newHeight
            frame.size.height = newHeight
        }

        window.setFrame(frame, display: true)
        self.frame = NSRect(origin: .zero, size: frame.size)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        activeResizeEdges = []
    }

    // MARK: Right-click context menu

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func showContextMenu(with event: NSEvent) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let menu = NSMenu()

        let biggerItem = NSMenuItem(title: "Bigger", action: #selector(AppDelegate.growClock), keyEquivalent: "")
        biggerItem.target = appDelegate
        menu.addItem(biggerItem)

        let smallerItem = NSMenuItem(title: "Smaller", action: #selector(AppDelegate.shrinkClock), keyEquivalent: "")
        smallerItem.target = appDelegate
        menu.addItem(smallerItem)

        menu.addItem(NSMenuItem.separator())

        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(AppDelegate.toggleColorMode), keyEquivalent: "")
        reverseItem.target = appDelegate
        reverseItem.state = isDarkMode ? .off : .on   // dark IS the default, so "reversed" means light
        menu.addItem(reverseItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let side = min(bounds.width, bounds.height)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = side / 2 - 4

        let now = Date()
        let comps = calendar.dateComponents([.hour, .minute, .second], from: now)
        let hour24 = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0

        drawDial(center: center, radius: radius)
        drawTicks(center: center, radius: radius)
        drawDate(center: center, radius: radius, now: now)
        drawHands(center: center, radius: radius, hour24: hour24, minute: minute, second: second)
        drawCenterPin(center: center, radius: radius)

        if isHovering {
            drawHoverBorder()
        }
    }

    private func drawDial(center: NSPoint, radius: CGFloat) {
        let path = NSBezierPath(ovalIn: rect(center: center, radius: radius))
        dialColor.setFill()
        path.fill()
        markColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawTicks(center: NSPoint, radius: CGFloat) {
        for i in 0..<60 {
            let angle = Double(i) * 6.0 * .pi / 180.0
            let isHourDot = i % 5 == 0
            let dotRadius = radius * 0.86 // pulled in from the edge to leave a visible gap

            let p = point(center: center, radius: dotRadius, angle: angle)
            let size = isHourDot ? radius * 0.055 : radius * 0.022
            let dotRect = NSRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)
            let path = NSBezierPath(ovalIn: dotRect)

            if isHourDot {
                markColor.setFill()
            } else {
                minorDotColor.setFill()
            }
            path.fill()
        }
    }

    private func drawDate(center: NSPoint, radius: CGFloat, now: Date) {
        let text = dateFormatter.string(from: now).uppercased()
        let font = NSFont.systemFont(ofSize: radius * 0.13, weight: .medium)
        let labelPoint = point(center: center, radius: radius * 0.42, angle: .pi) // straight down, above the 6 o'clock tick
        drawCenteredText(text, at: labelPoint, font: font, color: markColor)
    }

    private func drawHands(center: NSPoint, radius: CGFloat, hour24: Int, minute: Int, second: Int) {
        let hourAngle = (Double(hour24 % 12) + Double(minute) / 60.0) / 12.0 * 2 * .pi
        let minuteAngle = (Double(minute) + Double(second) / 60.0) / 60.0 * 2 * .pi
        let secondAngle = Double(second) / 60.0 * 2 * .pi

        // All three hands are now thick, rounded-cap strokes rather than
        // a tapered wedge/thin line — a sufficiently bold rounded-cap
        // stroke naturally reads as a pill/capsule shape, matching
        // System Info's PercentBar silhouette (just radial instead of
        // horizontal). Colors are pulled from the same five-dot palette
        // used in swiftCT's app icon, tying the whole utility family
        // together visually.
        drawPillHand(center: center, angle: hourAngle, length: radius * 0.50, lineWidth: radius * 0.085, color: hourHandColor)
        drawPillHand(center: center, angle: minuteAngle, length: radius * 0.78, lineWidth: radius * 0.060, color: minuteHandColor)
        drawPillHand(center: center, angle: secondAngle, length: radius * 0.88, lineWidth: radius * 0.028, color: secondHandColor)
    }

    /// A thick, rounded-cap stroked hand — reads as a pill/capsule shape,
    /// matching System Info's bar-graph style. Used for all three hands.
    private func drawPillHand(center: NSPoint, angle: Double, length: CGFloat, lineWidth: CGFloat, color: NSColor) {
        let tip = point(center: center, radius: length, angle: angle)
        let path = NSBezierPath()
        path.move(to: center)
        path.line(to: tip)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawCenterPin(center: NSPoint, radius: CGFloat) {
        let r = radius * 0.035
        let pinRect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        markColor.setFill()
        NSBezierPath(ovalIn: pinRect).fill()
    }

    private func drawHoverBorder() {
        let borderRect = bounds.insetBy(dx: borderInset, dy: borderInset)
        let path = NSBezierPath(ovalIn: borderRect)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        markColor.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }

    // MARK: Geometry / text helpers

    private func rect(center: NSPoint, radius: CGFloat) -> NSRect {
        NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Point at `radius` from `center`, `angle` in radians measured clockwise from straight up (12 o'clock).
    private func point(center: NSPoint, radius: CGFloat, angle: Double) -> NSPoint {
        NSPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y + radius * CGFloat(cos(angle)))
    }

    private func drawCenteredText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        text.draw(at: origin, withAttributes: attrs)
    }
}

// MARK: - Icon graphic for the About panel

func makeClockIcon(size: NSSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let center = NSPoint(x: size.width / 2, y: size.height / 2)
    let radius = min(size.width, size.height) / 2 - size.width * 0.06
    let mark = NSColor(calibratedRed: 89.0 / 255, green: 89.0 / 255, blue: 89.0 / 255, alpha: 1.0)

    // Dial
    let dialRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: dialRect).fill()
    mark.setStroke()
    let dialPath = NSBezierPath(ovalIn: dialRect)
    dialPath.lineWidth = size.width * 0.015
    dialPath.stroke()

    func iconPoint(angleDeg: Double, len: CGFloat) -> NSPoint {
        let rad = angleDeg * .pi / 180
        return NSPoint(x: center.x + len * CGFloat(sin(rad)), y: center.y + len * CGFloat(cos(rad)))
    }

    // Hour dots
    for i in 0..<12 {
        let angle = Double(i) * 30.0
        let dotRadius = radius * 0.82
        let p = iconPoint(angleDeg: angle, len: dotRadius)
        let dotSize = radius * 0.09
        let dotRect = NSRect(x: p.x - dotSize, y: p.y - dotSize, width: dotSize * 2, height: dotSize * 2)
        mark.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    // Hands fixed at a classic "10:09:30" watch-ad pose
    let hourTip = iconPoint(angleDeg: 304.5, len: radius * 0.5)
    let hourPath = NSBezierPath()
    hourPath.move(to: center)
    hourPath.line(to: hourTip)
    hourPath.lineWidth = radius * 0.09
    hourPath.lineCapStyle = .round
    mark.setStroke()
    hourPath.stroke()

    let minuteTip = iconPoint(angleDeg: 54, len: radius * 0.8)
    let minutePath = NSBezierPath()
    minutePath.move(to: center)
    minutePath.line(to: minuteTip)
    minutePath.lineWidth = radius * 0.045
    minutePath.lineCapStyle = .round
    mark.setStroke()
    minutePath.stroke()

    let secondTip = iconPoint(angleDeg: 180, len: radius * 0.85)
    let secondPath = NSBezierPath()
    secondPath.move(to: center)
    secondPath.line(to: secondTip)
    secondPath.lineWidth = radius * 0.02
    secondPath.lineCapStyle = .round
    NSColor.systemRed.setStroke()
    secondPath.stroke()

    let pinRadius = radius * 0.04
    let pinRect = NSRect(x: center.x - pinRadius, y: center.y - pinRadius, width: pinRadius * 2, height: pinRadius * 2)
    mark.setFill()
    NSBezierPath(ovalIn: pinRect).fill()

    return image
}

// MARK: - About panel

final class AboutWindowController: NSWindowController {

    convenience init(appName: String, tagline: String, version: String, icon: NSImage) {
        let panelSize = NSSize(width: 300, height: 320)
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

        let iconSize: CGFloat = 96
        let iconView = NSImageView(frame: NSRect(x: (panelSize.width - iconSize) / 2, y: panelSize.height - 30 - iconSize, width: iconSize, height: iconSize))
        iconView.image = icon
        contentView.addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = .boldSystemFont(ofSize: 18)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: iconView.frame.minY - 30, width: panelSize.width, height: 24)
        contentView.addSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: nameLabel.frame.minY - 18, width: panelSize.width, height: 16)
        contentView.addSubview(versionLabel)

        let taglineLabel = NSTextField(wrappingLabelWithString: tagline)
        taglineLabel.font = .systemFont(ofSize: 12)
        taglineLabel.alignment = .center
        taglineLabel.textColor = .labelColor
        taglineLabel.frame = NSRect(x: 24, y: 50, width: panelSize.width - 48, height: versionLabel.frame.minY - 60)
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

final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    var clockView: ClockFaceView!
    var timer: Timer?
    private var reverseColorsMenuItem: NSMenuItem?
    private var aboutWindowController: AboutWindowController?

    private let minWindowSize = NSSize(width: 100, height: 100)
    private let maxWindowSize = NSSize(width: 900, height: 900)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular) // real Dock icon, standard app menu bar, Cmd+Tab support

        let windowSize = NSSize(width: 220, height: 220)
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.midX - windowSize.width / 2
        let originY = screenFrame.midY - windowSize.height / 2

        window = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: windowSize.width, height: windowSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        // Remembers size and position across launches automatically —
        // if a frame was saved from a previous session, this restores
        // it immediately, overriding the centered default computed
        // above. No manual save/load code needed; AppKit handles both
        // the writing (on move/resize) and reading (here) itself.
        window.setFrameAutosaveName("swiftCLOCKv1MainWindow")

        clockView = ClockFaceView(frame: NSRect(origin: .zero, size: windowSize))
        clockView.minWindowSize = minWindowSize
        clockView.maxWindowSize = maxWindowSize
        clockView.sharedDarkModeOpacity = loadSharedTerminalOpacity()
        window.contentView = clockView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.clockView.needsDisplay = true
        }
        clockView.needsDisplay = true

        setUpMainMenu()
    }

    private func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Clock menu — sizing shortcuts and the reversed color mode
        let clockMenuItem = NSMenuItem()
        mainMenu.addItem(clockMenuItem)

        let clockMenu = NSMenu(title: "Clock")
        clockMenu.addItem(withTitle: "Bigger", action: #selector(growClock), keyEquivalent: "=")
        clockMenu.addItem(withTitle: "Smaller", action: #selector(shrinkClock), keyEquivalent: "-")
        clockMenu.addItem(NSMenuItem.separator())

        let reverseColorsItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "i")
        clockMenu.addItem(reverseColorsItem)
        self.reverseColorsMenuItem = reverseColorsItem

        clockMenuItem.submenu = clockMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func growClock() {
        resizeWindow(byDelta: 20)
    }

    @objc func shrinkClock() {
        resizeWindow(byDelta: -20)
    }

    @objc func toggleColorMode() {
        clockView.isDarkMode.toggle()
        reverseColorsMenuItem?.state = clockView.isDarkMode ? .off : .on
    }

    @objc private func showAboutPanel() {
        if aboutWindowController == nil {
            let icon = makeClockIcon(size: NSSize(width: 96, height: 96))
            aboutWindowController = AboutWindowController(
                appName: "SwiftClock",
                tagline: "A minimal analog clock face inspired by the classic Unix xclock.",
                version: "3.01.08c",
                icon: icon
            )
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Grows/shrinks the window by `delta` points on each axis, keeping it centered in place.
    private func resizeWindow(byDelta delta: CGFloat) {
        guard let window = window else { return }
        let currentFrame = window.frame

        let newWidth = max(minWindowSize.width, min(maxWindowSize.width, currentFrame.width + delta))
        let newHeight = max(minWindowSize.height, min(maxWindowSize.height, currentFrame.height + delta))

        let center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        let newOrigin = NSPoint(x: center.x - newWidth / 2, y: center.y - newHeight / 2)
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newWidth, height: newHeight))

        window.setFrame(newFrame, display: true)
        clockView.frame = NSRect(origin: .zero, size: newFrame.size)
        clockView.needsDisplay = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()