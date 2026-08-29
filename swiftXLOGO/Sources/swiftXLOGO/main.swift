// ═══════════════════════════════════════════════════════════════
// APP: swiftXLOGO
// A personal xlogo-style companion app -- NOT part of swiftSUITE
// proper, just a nostalgic nod to the classic X11 demo trio
// (xeyes, xclock, xlogo) built in the same modern visual language.
// File: Sources/swiftXLOGO/main.swift
// Updated: 2026-08-13
// ═══════════════════════════════════════════════════════════════

import Cocoa

// MARK: - LogoView
// Red is the dominant diagonal, bottom-left to top-right -- one
// continuous pill spanning its full length in a single rotation and a
// single fill (not two halves that happen to share a color, which left
// a visible seam at the join), with a transparent slot running through
// it via even-odd winding. Blue (above) and green (below) are the other
// diagonal's short independent arms, each pulled back from the exact
// center by a gap so neither touches red. Green matches red's own full
// size; blue is 90% of green's.
class LogoView: NSView {
    private let armBlue   = NSColor(calibratedRed: 145.0/255, green: 170.0/255, blue: 255.0/255, alpha: 1.0)   // matches the icon family's blue
    private let armGreen  = NSColor(calibratedRed: 52.0/255,  green: 199.0/255, blue: 89.0/255,  alpha: 1.0)   // matches the icon family's green
    private let armRed    = NSColor.systemRed

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let baseRadius = min(bounds.width, bounds.height) * 0.42
        // Thinner relative to length than before -- a thick/short pill
        // reads more circular-blobby, a thin/long one reads more
        // rectangular/linear, which is the actual lever for "looks
        // square" here rather than the window's own frame shape (that
        // stopped mattering visually once the background went fully
        // transparent -- only the arms' own proportions are visible now).
        let baseArmWidth = baseRadius * 0.18

        // Green restored to full size (matching red's own base values).
        // Blue at 90% of green's size, per the new hierarchy.
        let greenRadius = baseRadius
        let greenArmWidth = baseArmWidth
        let blueRadius = baseRadius * 0.90
        let blueArmWidth = baseArmWidth * 0.90

        // Gap sized off the dominant (red) arm's own width, since that's
        // the body green/blue need to visibly clear -- pulled in closer
        // than the previous pass.
        let gap = baseArmWidth * 0.6

        // Red's top-right end (the 45° direction) extends a hair past
        // its base length -- a small deliberate asymmetry rather than a
        // perfectly symmetric diagonal.
        let topRightExtension = baseRadius * 0.08

        // Red: the dominant diagonal, bottom-left to top-right (45°),
        // one continuous pill with the transparent cutout running
        // through it -- same technique that fixed the earlier seam:
        // one rotation, one path, one fill, not two halves sharing a color.
        drawDominantDiagonal(angleDegrees: 45, center: center, radius: baseRadius, positiveExtension: topRightExtension, armWidth: baseArmWidth, color: armRed)

        // Blue sits above the red diagonal (135°, pointing up-left),
        // green sits below it (315°, pointing down-right) -- both pulled
        // back from center by `gap` so neither touches red.
        drawShortArm(angleDegrees: 135, center: center, radius: blueRadius, armWidth: blueArmWidth, gap: gap, color: armBlue)
        drawShortArm(angleDegrees: 315, center: center, radius: greenRadius, armWidth: greenArmWidth, gap: gap, color: armGreen)
    }

    // The dominant diagonal, drawn as ONE continuous pill spanning the
    // full length in a single rotation and a single fill operation --
    // not two independently-drawn halves that happen to share a color.
    // Two separate fills meeting at the same color still produced a
    // visible seam at the join; one unified path has no join to see at all.
    // `positiveExtension` makes the positive (angleDegrees) end reach a
    // bit further than the negative (angleDegrees+180°) end -- a
    // deliberate small asymmetry rather than a perfectly mirrored diagonal.
    private func drawDominantDiagonal(angleDegrees: CGFloat, center: NSPoint, radius: CGFloat, positiveExtension: CGFloat, armWidth: CGFloat, color: NSColor) {
        let angle = angleDegrees * .pi / 180

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byRadians: angle)
        transform.concat()

        let positiveReach = radius + positiveExtension
        let armPath = NSBezierPath(roundedRect: NSRect(x: -radius, y: -armWidth / 2, width: radius + positiveReach, height: armWidth),
                                    xRadius: armWidth / 2, yRadius: armWidth / 2)

        let cutoutLength = radius * 0.92
        let cutoutWidth = armWidth * 0.55
        let cutoutRect = NSRect(x: -cutoutLength, y: -cutoutWidth / 2, width: cutoutLength * 2, height: cutoutWidth)
        armPath.append(NSBezierPath(roundedRect: cutoutRect, xRadius: cutoutWidth / 2, yRadius: cutoutWidth / 2))
        armPath.windingRule = .evenOdd

        color.setFill()
        armPath.fill()

        NSGraphicsContext.restoreGraphicsState()
    }

    // Green and blue -- each its own independent arm, pulled back from
    // the exact center by `gap` so neither touches the dominant diagonal.
    private func drawShortArm(angleDegrees: CGFloat, center: NSPoint, radius: CGFloat, armWidth: CGFloat, gap: CGFloat, color: NSColor) {
        let angle = angleDegrees * .pi / 180

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byRadians: angle)
        transform.concat()

        let armPath = NSBezierPath(roundedRect: NSRect(x: gap, y: -armWidth / 2, width: radius - gap, height: armWidth),
                                    xRadius: armWidth / 2, yRadius: armWidth / 2)
        color.setFill()
        armPath.fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - About panel
// Same pattern already used in swiftEYES/swiftCLOCK/swiftSYSINFO/swiftVIEW.

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

        let iconView = NSImageView(frame: NSRect(x: (panelSize.width - 60) / 2, y: 196, width: 60, height: 60))
        iconView.image = NSApplication.shared.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = .boldSystemFont(ofSize: 18)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: 164, width: panelSize.width, height: 24)
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
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var logoView: LogoView!
    var aboutWindowController: AboutWindowController?

    let minWindowSize = NSSize(width: 100, height: 100)
    let maxWindowSize = NSSize(width: 800, height: 800)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let startSize = NSSize(width: 260, height: 200)
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: (screenFrame.width - startSize.width) / 2, y: (screenFrame.height - startSize.height) / 2)
        let frame = NSRect(origin: origin, size: startSize)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        // Remembers size and position across launches automatically.
        window.setFrameAutosaveName("swiftXLOGOMainWindow")

        logoView = LogoView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = logoView

        setUpMainMenu()
        window.contentView?.menu = buildContextMenu()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menus

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bigger", action: #selector(growLogo), keyEquivalent: "")
        menu.addItem(withTitle: "Smaller", action: #selector(shrinkLogo), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About swiftXLOGO", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit swiftXLOGO", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Bigger", action: #selector(growLogo), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Smaller", action: #selector(shrinkLogo), keyEquivalent: "-")
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Resize

    @objc func growLogo() {
        resizeWindow(byDelta: 20)
    }

    @objc func shrinkLogo() {
        resizeWindow(byDelta: -20)
    }

    private func resizeWindow(byDelta delta: CGFloat) {
        guard let window = window else { return }
        let currentFrame = window.frame

        let newWidth = max(minWindowSize.width, min(maxWindowSize.width, currentFrame.width + delta))
        let newHeight = max(minWindowSize.height, min(maxWindowSize.height, currentFrame.height + delta))

        let center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        let newOrigin = NSPoint(x: center.x - newWidth / 2, y: center.y - newHeight / 2)
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newWidth, height: newHeight))

        window.setFrame(newFrame, display: true)
        logoView.frame = NSRect(origin: .zero, size: newFrame.size)
        logoView.needsDisplay = true
    }

    @objc func showAboutPanel() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController(
                appName: "swiftXLOGO",
                tagline: "A modern take on the original UNIX xlogo — it does nothing but look good on your screen.",
                version: "3.01.08c"
            )
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()