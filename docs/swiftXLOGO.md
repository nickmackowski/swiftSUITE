# swiftXLOGO

A personal, nostalgic nod to the classic X11 demo trio — alongside swiftEYES and swiftCLOCK, this completes the set with an original take on xlogo, the third of the three utilities that shipped with virtually every X11 installation.

An original geometric design inspired by the concept of the historical X Window System logo, not a reproduction of it — same approach already used for swiftEYES and swiftCLOCK.

---

## Design

The X is built as two crossing diagonals rather than four independent arms:

- **Red** is the dominant diagonal, running bottom-left to top-right — one continuous pill shape with a transparent slot running its full length, genuinely punched through (not a color choice) so whatever's behind the window shows through it. Its top-right end extends slightly past its bottom-left end, a deliberate small asymmetry.
- **Blue** and **green** form the other diagonal — two short independent arms (blue above, green below), each pulled back from the shared center by a small gap so neither touches red.
- Sizing follows a clock-hand-style hierarchy: red is longest and thickest, green matches red's own length, and blue sits at 90% of green's size.

The background is fully transparent — there's no window chrome or fill behind the shape, so only the X itself is visible against whatever's on your desktop underneath it.

---

## Right-Click Menu

- **Bigger / Smaller** — resizes the window; the whole shape is drawn proportionally to the view's own bounds, so resizing the window scales everything together
- **Quit**

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)

---

## Building

Swift Package Manager project, built as a universal binary (arm64 + x86_64) via its own `build.sh`:

```bash
cd swiftXLOGO
./build.sh
```

Or via swiftADMIN (auto-detected by the presence of `Package.swift`):

```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps, or [2] to build swiftXLOGO specifically
```

---

Part of the [swiftSUITE](../README.md) collection.
