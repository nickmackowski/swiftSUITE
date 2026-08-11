// ═══════════════════════════════════════════════════════════════
// APP: swiftEYES
// xeyes-style floating companion app
// File: Sources/swiftEYES/main.swift
// ═══════════════════════════════════════════════════════════════

import Cocoa

// MARK: - EyesView
// Draws N eyeballs and animates each pupil toward the current global mouse location.

final class EyesView: NSView {

    // Number of eyes to draw side by side. 2 = classic xeyes.
    var eyeCount: Int = 2

    // Colors — light mode is the classic white sclera / black pupil; dark mode
    // matches swiftLT's "Clear Dark" theme (its default) for consistency across the suite.
    private let lightScleraColor = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)          // #FFFFFF
    private let lightMarkColor = NSColor(calibratedRed: 89.0/255, green: 89.0/255, blue: 89.0/255, alpha: 1.0)  // #595959
    private let darkScleraColor = NSColor(calibratedRed: 0.098039, green: 0.113725, blue: 0.152941, alpha: 1.0) // swiftLT "Clear Dark" background
    private let darkMarkColor = NSColor.white                                                                    // swiftLT "Clear Dark" foreground

    var isDarkMode = false {
        didSet { needsDisplay = true }
    }

    private var scleraColor: NSColor { isDarkMode ? darkScleraColor : lightScleraColor }
    private var markColor: NSColor { isDarkMode ? darkMarkColor : lightMarkColor }

    // Visual tuning
    private let marginRatio: CGFloat = 0.10   // margin as a fraction of the view's height, so the gap between eyes scales with window size instead of staying a fixed pixel amount
    private let pupilRadiusRatio: CGFloat = 0.28   // pupil radius as fraction of eye radius
    private let pupilTravelRatio: CGFloat = 0.55   // how far off-center the pupil can move, as fraction of eye radius

    // Border / resize handle tuning
    private let edgeGrabMargin: CGFloat = 8        // how close to an edge counts as "on the border"
    private let borderInset: CGFloat = 1.5
    private var isHovering = false

    // Resize state while actively dragging an edge/corner
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

    var minWindowSize = NSSize(width: 80, height: 40)
    var maxWindowSize = NSSize(width: 1000, height: 500)

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

    // MARK: Resize dragging

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
        if horizontal && vertical { return .crosshair }        // corner (AppKit has no public diagonal cursor)
        if horizontal { return .resizeLeftRight }
        if vertical { return .resizeUpDown }
        return .arrow
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = edges(at: point)

        guard !edges.isEmpty, let window = self.window else {
            // Not on the border — let the window handle it normally (background dragging to move).
            super.mouseDown(with: event)
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

        let biggerItem = NSMenuItem(title: "Bigger", action: #selector(AppDelegate.growEyes), keyEquivalent: "")
        biggerItem.target = appDelegate
        menu.addItem(biggerItem)

        let smallerItem = NSMenuItem(title: "Smaller", action: #selector(AppDelegate.shrinkEyes), keyEquivalent: "")
        smallerItem.target = appDelegate
        menu.addItem(smallerItem)

        menu.addItem(NSMenuItem.separator())

        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(AppDelegate.toggleColorMode), keyEquivalent: "")
        reverseItem.target = appDelegate
        reverseItem.state = isDarkMode ? .on : .off
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

        let count = max(1, eyeCount)
        let eyeMargin = bounds.height * marginRatio
        let totalMargin = eyeMargin * CGFloat(count + 1)
        let eyeWidth = (bounds.width - totalMargin) / CGFloat(count)
        let eyeSize = min(eyeWidth, bounds.height - 2 * eyeMargin)

        // Current mouse location in screen coordinates (bottom-left origin, same as window frame).
        let mouseScreen = NSEvent.mouseLocation

        guard let window = self.window else { return }

        for i in 0..<count {
            let x = eyeMargin + CGFloat(i) * (eyeWidth + eyeMargin) + (eyeWidth - eyeSize) / 2
            let y = (bounds.height - eyeSize) / 2
            let eyeRect = NSRect(x: x, y: y, width: eyeSize, height: eyeSize)

            drawEye(eyeRect: eyeRect, mouseScreen: mouseScreen, window: window, ctx: ctx)
        }

        if isHovering {
            drawHoverBorder()
        }
    }

    private func drawHoverBorder() {
        let borderRect = bounds.insetBy(dx: borderInset, dy: borderInset)
        let path = NSBezierPath(rect: borderRect)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        markColor.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }

    private func drawEye(eyeRect: NSRect, mouseScreen: NSPoint, window: NSWindow, ctx: CGContext) {
        // Eyeball
        let eyePath = NSBezierPath(ovalIn: eyeRect)
        scleraColor.setFill()
        eyePath.fill()
        markColor.setStroke()
        eyePath.lineWidth = 2.5
        eyePath.stroke()

        // Convert this eye's center to screen coordinates.
        let eyeCenterInView = NSPoint(x: eyeRect.midX, y: eyeRect.midY)
        let eyeCenterInWindow = self.convert(eyeCenterInView, to: nil)
        let eyeCenterOnScreen = window.convertPoint(toScreen: eyeCenterInWindow)

        let dx = mouseScreen.x - eyeCenterOnScreen.x
        let dy = mouseScreen.y - eyeCenterOnScreen.y
        let distance = sqrt(dx * dx + dy * dy)

        let eyeRadius = eyeRect.width / 2
        let maxTravel = eyeRadius * pupilTravelRatio
        let travel = min(distance, maxTravel)

        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        if distance > 0.001 {
            offsetX = CGFloat(dx / distance) * travel
            offsetY = CGFloat(dy / distance) * travel
        }

        let pupilRadius = eyeRadius * pupilRadiusRatio
        let pupilCenter = NSPoint(x: eyeRect.midX + offsetX, y: eyeRect.midY + offsetY)
        let pupilRect = NSRect(
            x: pupilCenter.x - pupilRadius,
            y: pupilCenter.y - pupilRadius,
            width: pupilRadius * 2,
            height: pupilRadius * 2
        )
        let pupilPath = NSBezierPath(ovalIn: pupilRect)
        markColor.setFill()
        pupilPath.fill()
    }
}

// MARK: - Icon graphic for the About panel

func makeEyesIcon(size: NSSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let margin: CGFloat = size.width * 0.08
    let eyeSize = min((size.width - margin * 3) / 2, size.height - margin * 2)
    let totalWidth = eyeSize * 2 + margin
    let startX = (size.width - totalWidth) / 2
    let y = (size.height - eyeSize) / 2

    for i in 0..<2 {
        let x = startX + CGFloat(i) * (eyeSize + margin)
        let eyeRect = NSRect(x: x, y: y, width: eyeSize, height: eyeSize)
        let eyePath = NSBezierPath(ovalIn: eyeRect)
        NSColor.white.setFill()
        eyePath.fill()
        NSColor(calibratedWhite: 0.15, alpha: 1.0).setStroke()
        eyePath.lineWidth = size.width * 0.018
        eyePath.stroke()

        let pupilRadius = eyeSize * 0.28
        let offset = eyeSize * 0.10
        let pupilCenter = NSPoint(x: eyeRect.midX + offset, y: eyeRect.midY + offset)
        let pupilRect = NSRect(x: pupilCenter.x - pupilRadius, y: pupilCenter.y - pupilRadius, width: pupilRadius * 2, height: pupilRadius * 2)
        NSColor(calibratedWhite: 0.15, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: pupilRect).fill()
    }

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
    var eyesView: EyesView!
    var timer: Timer?
    private var reverseColorsMenuItem: NSMenuItem?
    private var aboutWindowController: AboutWindowController?

    private let minWindowSize = NSSize(width: 80, height: 40)
    private let maxWindowSize = NSSize(width: 1000, height: 500)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular) // real Dock icon, standard app menu bar, Cmd+Tab support

        let windowSize = NSSize(width: 220, height: 110)
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
        window.hasShadow = false
        window.level = .floating                 // stays on top of other windows
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true // drag anywhere (away from the border) to move it
        window.ignoresMouseEvents = false         // set true instead if you want click-through
        window.acceptsMouseMovedEvents = true

        eyesView = EyesView(frame: NSRect(origin: .zero, size: windowSize))
        eyesView.minWindowSize = minWindowSize
        eyesView.maxWindowSize = maxWindowSize
        window.contentView = eyesView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Redraw ~60x/sec so pupils track the mouse smoothly.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.eyesView.needsDisplay = true
        }

        setUpMainMenu()
    }

    // Standard macOS app menu: About / Hide / Hide Others / Show All / Quit — plus an Eyes menu for sizing.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // App menu (the bold "SwiftEyes" menu at the far left)
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

        // Eyes menu — sizing shortcuts and the reversed color mode
        let eyesMenuItem = NSMenuItem()
        mainMenu.addItem(eyesMenuItem)

        let eyesMenu = NSMenu(title: "Eyes")
        eyesMenu.addItem(withTitle: "Bigger", action: #selector(growEyes), keyEquivalent: "=")
        eyesMenu.addItem(withTitle: "Smaller", action: #selector(shrinkEyes), keyEquivalent: "-")
        eyesMenu.addItem(NSMenuItem.separator())

        let reverseColorsItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "i")
        eyesMenu.addItem(reverseColorsItem)
        self.reverseColorsMenuItem = reverseColorsItem

        eyesMenuItem.submenu = eyesMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func growEyes() {
        resizeWindow(byDelta: 20)
    }

    @objc func shrinkEyes() {
        resizeWindow(byDelta: -20)
    }

    @objc func toggleColorMode() {
        eyesView.isDarkMode.toggle()
        reverseColorsMenuItem?.state = eyesView.isDarkMode ? .on : .off
    }

    @objc private func showAboutPanel() {
        if aboutWindowController == nil {
            let icon = makeEyesIcon(size: NSSize(width: 96, height: 96))
            aboutWindowController = AboutWindowController(
                appName: "SwiftEyes",
                tagline: "A tiny transparent eyes toy that follows your cursor around the screen.",
                version: "1.0",
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
        let newHeight = max(minWindowSize.height, min(maxWindowSize.height, currentFrame.height + delta / 2))

        let center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        let newOrigin = NSPoint(x: center.x - newWidth / 2, y: center.y - newHeight / 2)
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newWidth, height: newHeight))

        window.setFrame(newFrame, display: true)
        eyesView.frame = NSRect(origin: .zero, size: newFrame.size)
        eyesView.needsDisplay = true
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