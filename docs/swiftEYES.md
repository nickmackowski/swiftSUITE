# swiftEYES

A classic xeyes-style companion app — a small floating pair of eyes that tracks your cursor wherever it goes on screen.

---

## Features

- **Global cursor tracking** — the eyes follow your mouse position across the entire screen, not just within the app's own window
- **Borderless floating window** — sits on top of your other windows without a title bar or standard chrome
- **Resizable via right-click menu** — Bigger / Smaller, adjusting the whole window (the drawing is proportional to the window's own size, so everything scales together automatically)
- **Reverse Colors** — swaps between light and dark eye styling
- **Configurable as a swiftCT Utility slot** — launch it directly from swiftCT's Utilities menu, or run standalone

---

## Right-Click Menu

- **Bigger / Smaller** — resizes the window; since the eyes are drawn proportionally to the view's own bounds, resizing the window is all that's needed to scale everything
- **Reverse Colors** — toggles light/dark styling
- **Quit**

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)

---

## Building

Swift Package Manager project, built as a universal binary (arm64 + x86_64) via its own `build.sh`:

```bash
cd swiftEYES
./build.sh
```

Or via swiftADMIN (auto-detected by the presence of `Package.swift`):

```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps, or [2] to build swiftEYES specifically
```

---

Part of the [swiftSUITE](../README.md) collection. Launchable directly from [swiftCT](swiftCT.md)'s Utilities menu.
