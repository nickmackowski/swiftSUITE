# swiftCT

A native macOS terminal launcher built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with 11 built-in color themes, SSH remote session support, and a configurable Utilities menu for launching companion apps.

---

## Features

- **11 built-in themes** — Basic, Clear Dark (default), Clear Light, Grass, Homebrew, Man Page, Novel, Ocean, Pro, Red Sands, Silver Aerogel
- **Live preview while browsing Settings** — the actual terminal window updates as you click through themes, not a separate mockup
- **3 cursor styles** — Block, Underline, Bar — with an optional blink toggle
- **SSH remote sessions** — connect to remote hosts in their own dedicated windows, independent lifecycle from the main terminal, styled to match whatever theme the main window is currently using
- **Utilities menu** — up to 6 configurable launch slots for quick access to companion apps or any other application, editable from Settings
- **Services integration** — optional Syncthing and Tailscale status checks, consumed by swiftSYSINFO (see below)

---

## Utilities Menu

swiftCT can launch other apps directly from its menu bar — both the swiftSUITE companion apps built alongside it, and any other application on your Mac.

- **Companion slots** resolve dynamically by name each time they're launched, so they keep working even if the swiftSUITE folder moves.
- **Custom slots** point to an absolute path, picked via a file browser, for launching anything else you'd like quick access to.
- Manage slots from **Settings → Utilities** — add up to 6, remove any you don't use.

The swiftSUITE companion apps you can launch this way each have their own dedicated documentation:

- [swiftEYES](swiftEYES.md) — a classic xeyes-style floating companion, tracking your cursor
- [swiftCLOCK](swiftCLOCK.md) — an analog clock, available in a plain v1 and an enhanced v2 with tracking eyes, a Day-Date-style calendar window, and a 24-hour digital readout
- [swiftSYSINFO](swiftSYSINFO.md) — a BGInfo-style system telemetry dashboard, covering hardware info, live resource usage, and network/VPN/sync status

---

## Services (Syncthing / Tailscale / VPN)

swiftCT's Settings includes a **Services** section that configures live status checks consumed by swiftSYSINFO — not swiftCT itself. This keeps configuration in one place rather than scattering credentials and paths across every companion app.

Configurable there:

- **Syncthing API Key** — found in Syncthing's own web UI under Settings → GUI
- **Syncthing Folder ID(s)** — comma-separated if you're tracking multiple folders; status reflects whichever folder is *least* caught up, not just the first one checked
- **Tailscale Binary Path** — browsable via a file picker rather than typed manually, since the actual binary sits nested inside `Tailscale.app`'s bundle
- **Show/hide toggles** for the Tailscale, Syncthing, and VPN rows in swiftSYSINFO, in case you don't use one or more of these services

This data is stored in a shared config file (`swiftCT/.swiftsuite-config.json` as of this version — see note below) that both swiftCT and swiftSYSINFO read from.

> **Note:** this file's exact location has moved during development. If you're working from an older build, check `swiftCT/swiftsuite-config.json` (no leading dot) or the swiftSUITE root as fallback locations before assuming it's missing entirely.

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)

---

## Building

swiftCT is a Swift Package Manager project, built as a universal binary (arm64 + x86_64) via its own `build.sh`:

```bash
cd swiftCT
./build.sh
```

Or via swiftADMIN, which detects any project folder containing a `Package.swift` automatically:

```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps, or [2] to build swiftCT specifically
```

`build.sh` handles the per-architecture build, `lipo` merge, app bundle assembly, icon embedding, and code signing in one step.

---

## Settings

Opened via the app menu or the standard macOS Settings shortcut. Organized into three grouped sections:

- **Appearance** — Cursor style and blink
- **Utilities** — up to 6 launch slots
- **Services** — Syncthing/Tailscale/VPN configuration for swiftSYSINFO

Theme selection lives in the sidebar on the left, with a live preview on the right that reflects your choice immediately — the real terminal window updates too, so you can see exactly how a theme looks before committing. Changes are previewed live but only persist once you click **Default**; closing Settings without doing so reverts to whatever was previously saved.

---

## Acknowledgements

Built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza. Part of the [swiftSUITE](../README.md) collection of terminal-based productivity apps.
