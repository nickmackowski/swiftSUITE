# swiftCLOCK

A flat, minimal analog clock companion app, available in two versions — a clean original design (v1), and an enhanced version (v2) adding tracking eyes and additional complications inspired by classic watch dial design.

---

## swiftCLOCKv1

The original design — a flat, minimal analog face in the style of Xclock: dot hour/minute markers (bold dots at each hour), a short thick hour hand, a long thin minute hand, a red second hand, and the date shown as plain text.



---

## swiftCLOCKv2

Builds on v1 with three additions inspired by real watch dial conventions — each replacing what would otherwise be an hour marker at that position, the same way a Rolex Datejust has no numeral at 3 o'clock because that's exactly where its date window sits:

- **Tracking eyes at 6 o'clock** — genuine cursor-tracking (not decorative), using the same pupil-tracking math as swiftEYES, ported directly into the clock face's own drawing
- **Date window at 3 o'clock** — Day-Date style, showing the day-of-week abbreviation and date number (e.g. "SUN 09"), with **Sunday shown in red** — a traditional watch dial convention
- **24-hour digital readout at 9 o'clock** — plain digital time display alongside the analog hands

Hands are colored blue (hour), green (minute), and red (second), rendered as thick rounded-cap pills rather than thin lines. Hands render on top of the eyes and complications, so the periodic sweep of the hour hand through 6 o'clock (and the minute/hour hands through 3 and 9 at various points) is expected — the same way a real watch's hands pass over its own complications during normal operation.

<img width="372" height="374" alt="image" src="https://github.com/user-attachments/assets/e11547cf-8607-4a53-b6e2-bea50be8cbac" />


---

## Right-Click Menu

Both versions share the same menu:

- **Bigger / Smaller** — resizes the window; the whole face is drawn proportionally to the view's own bounds, so resizing the window scales everything together
- **Reverse Colors** — toggles light/dark styling
- **Quit**

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)

---

## Building

Both versions are separate Swift Package Manager projects, each built as a universal binary (arm64 + x86_64) via their own `build.sh`:

```bash
cd swiftCLOCKv1   # or swiftCLOCKv2
./build.sh
```

Or via swiftADMIN (auto-detected by the presence of `Package.swift`):

```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps, or [2] to build a specific version
```

---

Part of the [swiftSUITE](../README.md) collection. Launchable directly from [swiftCT](swiftCT.md)'s Utilities menu.
