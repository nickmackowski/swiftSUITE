// ═══════════════════════════════════════════════════════════════
// swiftADMIN helper: set_folder_icon.swift
// Applies a custom icon to a folder via NSWorkspace — run directly as
// a script (no compile step needed): swift set_folder_icon.swift <icon.png> <folder>
// Called by swiftADMIN.py at the end of a successful build-all run, to
// unconditionally reapply the swiftSUITE folder icon every time. Not
// trying to detect whether it "went back to default" first — just
// always reapplying is simpler and just as effective, since setting an
// already-correct icon is harmless.
// ═══════════════════════════════════════════════════════════════

import Cocoa

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("Usage: swift set_folder_icon.swift <icon.png> <folder path>")
    exit(1)
}

let iconPath = arguments[1]
let folderPath = arguments[2]

guard let icon = NSImage(contentsOfFile: iconPath) else {
    print("Could not load icon image at \(iconPath)")
    exit(1)
}

guard FileManager.default.fileExists(atPath: folderPath) else {
    print("Target folder does not exist: \(folderPath)")
    exit(1)
}

let success = NSWorkspace.shared.setIcon(icon, forFile: folderPath, options: [])
if success {
    print("Folder icon applied: \(folderPath)")
    exit(0)
} else {
    print("Failed to apply folder icon to \(folderPath)")
    exit(1)
}
