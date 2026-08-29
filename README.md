# swiftSUITE
A personal productivity suite built entirely in Swift for macOS terminals. Seven compiled command-line apps sharing a unified login, consistent visual design, and keyboard navigation — accessible locally or from any browser on your network via [ttyd](https://github.com/tsl0922/ttyd) and Tailscale, or through swiftCT, a native local launcher (see below). Beta Notice: This software is currently in development. While it is functional, you may encounter bugs, glitches, unexpected behavior, or incomplete features. If the application becomes unresponsive or behaves unexpectedly, pressing Ctrl+Z and restarting swiftCORE may be enough to zap "the ghost in the machine." Please use this software with caution, report any issues you encounter, and always keep backups of your data.  Thanks and enjoy ;-)

<img width="1280" height="640" alt="image" src="https://github.com/user-attachments/assets/ceed37d7-fac6-4e9c-b208-f29574c739c0" />

## The Story Behind This Project
Version 1.0 of swiftSUITE was developed with the assistance of Google Gemini. Version 2.0 was significantly refined, expanded, and rebuilt with the assistance of Anthropic Claude. Version 3.0 brought a coordinated, suite-wide release across every app at once — consistent header styling, directory layout, and log handling everywhere, plus real new features in swiftNOTES and swiftCALENDAR. The `c` suffix on every version number is a small nod to that collaboration. Version numbers are derived from the date of the most recent compile. If you modify the source code, please preserve the existing versioning convention: `major.minor.MM.DDc`, where MM is the month and DD is the day of the release. As of v3.0, every app in the suite — including swiftCALENDAR, which had drifted ahead of the others under the old v2.x numbering — shares the same `v3.01.MM.DDc` scheme.
I am not a professional programmer or software developer. This project is a demonstration of what becomes possible when a idea and AI-assistance development come together. If you have an idea for a personal tool and think you lack the technical background to build it — this project is proof that you might be wrong. 
Fun Fact: Claude AI even helped write this README and most of the supporting documentation ;-) Like the rest of the project, it's not perfect—but hopefully it's useful. If you spot anything that needs improvement, feel free to update it.  Thanks and have a great day!

---
## Apps
| App | Binary | Description |
|-----|--------|-------------|
| swiftCORE | `swiftCORE` | Launcher and authentication hub |
| swiftSTOCKS | `swiftSTOCKS` | Portfolio tracker with live market data |
| swiftNOTES | `swiftNOTES` | AES-256 encrypted notebook, with remote capture via email/text |
| swiftVAULT | `swiftVAULT` | AES-256 encrypted password manager |
| swiftCONTACTS | `swiftCONTACTS` | AES-256 encrypted contact manager |
| swiftCALENDAR | `swiftCALENDAR` | Calendar with ICS, METAR, and TAF support, plus live birthday and due-date overlays |
| swiftMAIL | `swiftMAIL` | IMAP/SMTP email client |
| swiftBASE | `swiftBASE` | Personal database app — user-definable fields, multiple independent databases, global search |
| swiftCT | `swiftCT` | Terminal Launcher for swiftCORE |
`swiftADMIN` is a companion tool — a Python toolkit (not a compiled Swift binary) for building, ttyd management, and factory reset. `swiftCT` is a tenth companion tool — a native macOS terminal launcher for swiftCORE, no browser required. See their own sections further down.

---
## Documentation
Detailed setup and usage guides for each app:
- [swiftCORE](docs/swiftCORE.md) 
- [swiftNOTES](docs/swiftNOTES.md) 
- [swiftVAULT](docs/swiftVAULT.md)
- [swiftCONTACTS](docs/swiftCONTACTS.md)
- [swiftSTOCKS](docs/swiftSTOCKS.md)
- [swiftCALENDAR](docs/swiftCALENDAR.md)
- [swiftMAIL](docs/swiftMAIL.md)
- [swiftBASE](docs/swiftBASE.md)
- [swiftADMIN](docs/swiftADMIN.md)
- [swiftCT](docs/swiftCT.md)
- [swiftEYES](docs/swiftEYES.md)
- [swiftCLOCK](docs/swiftCLOCK.md)
- [swiftSYSINFO](docs/swiftSYSINFO.md)
- [swiftXLOGO](docs/swiftXLOGO.md)
- [swiftVIEW](docs/swiftVIEW.md)

---
## Features
- **Unified auth** — log in once via swiftCORE; Notes, Vault, and Contacts unlock automatically for 30 minutes
- **120-column design system** — rounded box UI, greenbar grids, alphabetical nav footer across all apps
- **AES-256-GCM encryption** — Notes, Vault, and Contacts data encrypted at rest
- **Live navigation** — single-key jumps between all apps via `execv`, no launcher round-trips
- **Web accessible** — serve the full suite in any browser via ttyd + Tailscale
- **Native local launcher** — swiftCT drops you straight into swiftCORE with a native macOS app, no browser or ttyd required; double-click for a GUI window, or run it directly from a shell
- **Companion utilities** — swiftEYES, swiftCLOCK, swiftSYSINFO, swiftXLOGO, and swiftVIEW extend swiftCT with quick-access desktop tools, launchable from its Utilities menu; swiftCLOCKv2 adds live cursor-tracking eyes and Day-Date-style complications to its watch face, swiftSYSINFO surfaces VPN/Tailscale/Syncthing status alongside live CPU/memory/disk telemetry, swiftXLOGO is a nostalgic floating xlogo with a genuinely transparent background, and swiftVIEW is a read-only glance at today's and tomorrow's calendar, weather, and notes together in one list
- **Aviation weather** — one combined setup in swiftCALENDAR creates both a live METAR (current conditions) and TAF (forecast) account from a single airport code, with the real airport name and city decoded in the detail view
- **ICS calendar sync** — supports any CalDAV/ICS feed (iCloud, Outlook, Google Calendar)
- **Calendar overlays** — birthdays (from swiftCONTACTS) and due-date reminders (from swiftNOTES) appear automatically on swiftCALENDAR's month view, computed live on every launch — nothing is duplicated or stored twice
- **Remote capture** — email or text a note (or a real calendar event) to a dedicated inbox from anywhere, and it shows up automatically the next time swiftNOTES or swiftCALENDAR opens; swiftNOTES supports more than one capture inbox at once
- **15-minute auto-sync** — swiftMAIL polls in the background without requiring manual refresh
- **Personal database app** — swiftBASE lets you define your own fields and keep multiple independent databases, with search scoped to one database or global across all of them at once
- **swiftADMIN** — Python toolkit for building, ttyd management, and factory reset

---
## Requirements
- macOS 14 (Sonoma) or later
- Xcode Command Line Tools
  ```bash
  xcode-select --install
  ```
- Python 3.9+ (for `calendar_sync.py`, `notes_capture.py`, and `swiftADMIN.py`)
- Python packages
  ```bash
  pip3 install rich cryptography
  ```
- Homebrew (optional, required for ttyd — see Web Access section below)

---
## Installation
### 1. Clone the repository
```bash
git clone https://github.com/nickmackowski/swiftSUITE.git
cd swiftSUITE
```
### 2. Build all apps
The easiest way in: double-click **`Start Here (swiftADMIN).command`** right in the swiftSUITE folder — it opens Terminal and launches swiftADMIN for you, no manual commands needed.
Or from a shell:
```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps
```
A successful build also automatically creates a friendly **"Open swiftSUITE (swiftCT).app"** alias right in the swiftSUITE folder — that's the recommended way to actually launch the suite (see First Launch below).
Build time on my M1 MacBook Pro takes approximately 3-4 minutes, please be patient ;-)
Or build manually:
```bash
cd swiftCORE
swiftc -target arm64-apple-macosx14.0 scl.main.swift -o swiftCORE_arm64
swiftc -target x86_64-apple-macosx14.0 scl.main.swift -o swiftCORE_x86
lipo -create swiftCORE_arm64 swiftCORE_x86 -output swiftCORE
```
Repeat for each app directory. If an app's source has been moved into its own `source_code/` subfolder (see Directory Structure below), adjust the path in the `swiftc` command accordingly — `swiftADMIN` handles this automatically either way.
> **Why two build methods?** The seven core apps above are pure terminal programs — they read/write stdin/stdout directly, with no windows or GUI framework, so a single `.swift` file compiled straight via `swiftc` is genuinely the simplest correct approach. `swiftCT` and its five companion utilities (`swiftEYES`, `swiftCLOCK`, `swiftSYSINFO`, `swiftXLOGO`, `swiftVIEW`) are real native macOS GUI apps — actual windows, buttons, and menus — which fundamentally requires an `.app` bundle (Finder won't treat something as a proper double-clickable application without one) and, for swiftCT specifically, Swift Package Manager, since that's the only way to pull in an external dependency like SwiftTerm at all. This is standard practice in Swift development generally — CLI tools and GUI apps almost always have separate build setups, even within one larger codebase. `swiftADMIN`'s Build All Apps handles both transparently — you never have to think about which one an app needs — auto-detecting SPM projects by the presence of `Package.swift` and running that app's own `build.sh`, which produces both a native `.app` bundle and a standalone CLI binary. Build any of the six manually with `cd <app folder> && ./build.sh`. See [docs/swiftCT.md](docs/swiftCT.md) for swiftCT's own details.
### 3. First launch
The recommended way in is `swiftCT` — a native macOS app that drops you straight into swiftCORE, no browser or shell command needed. After Build All Apps completes, an alias is created automatically right in the swiftSUITE folder:
```
Open swiftSUITE (swiftCT).app
```
Just double-click it. (If you ever need to recreate it manually — say, after moving the folder — swiftADMIN's **[6] Refresh "Open swiftSUITE (swiftCT)" Alias** does it in one step.)
Prefer a shell? Run swiftCT directly for a zero-frills passthrough into swiftCORE:
```bash
cd swiftCT
./swiftCT
```
Or, if you'd rather skip swiftCT entirely and run swiftCORE on its own:
```bash
cd swiftCORE
./swiftCORE
```
On first run, swiftCORE prompts you to create a username and password. This password encrypts your Notes, Vault, and Contacts data.
<img width="2314" height="1688" alt="image" src="https://github.com/user-attachments/assets/f07241c1-f696-4a40-98a7-f26df76b2b79" />
See [swiftCT's documentation](docs/swiftCT.md) for its full feature set — themes, SSH remote sessions, and the Utilities menu for launching companion apps.

---
## Directory Structure
Each app's folder keeps its compiled binary and data files loose at the top level — this is deliberate, since the app resolves its own data directory relative to wherever the binary itself lives. Source code and logs are kept in their own subfolders alongside it:
```
swiftSUITE/
├── swiftADMIN/
│   └── swiftADMIN.py          # Build, ttyd, and admin toolkit
├── swiftCALENDAR/
│   ├── swiftCALENDAR          # compiled binary
│   ├── calendar_accounts.json
│   ├── known_airports.json
│   ├── logs/
│   └── source_code/
│       ├── sccm.main.swift
│       └── calendar_sync.py   # ICS / METAR / TAF sync engine
├── swiftCLOCKv1/
│   ├── swiftCLOCKv1.app        # original design, no complications
│   ├── swiftCLOCKv1
│   ├── Package.swift
│   ├── Info.plist
│   ├── build.sh
│   └── Sources/
│       └── swiftCLOCKv1/
│           └── main.swift
├── swiftCLOCKv2/
│   ├── swiftCLOCKv2.app        # adds tracking eyes and Day-Date complications
│   ├── swiftCLOCKv2
│   ├── Package.swift
│   ├── Info.plist
│   ├── build.sh
│   └── Sources/
│       └── swiftCLOCKv2/
│           └── main.swift
├── swiftCONTACTS/
│   ├── swiftCONTACTS
│   ├── logs/
│   └── source_code/
│       └── scc.main.swift
├── swiftCORE/
│   ├── swiftCORE
│   ├── logs/
│   └── source_code/
│       └── scl.main.swift
├── swiftCT/
│   ├── swiftCT.app             # native terminal launcher (double-click)
│   ├── swiftCT                 # standalone CLI binary (run ./swiftCT directly)
│   ├── Package.swift
│   ├── Info.plist
│   ├── build.sh
│   ├── README.md
│   ├── THIRD-PARTY-LICENSES.md # SwiftTerm's MIT license
│   ├── swiftsuite-config.json  # shared config, also read by swiftSYSINFO
│   └── Sources/
│       └── swiftCT/
│           └── main.swift
├── swiftEYES/
│   ├── swiftEYES.app
│   ├── swiftEYES
│   ├── Package.swift
│   ├── Info.plist
│   ├── build.sh
│   └── Sources/
│       └── swiftEYES/
│           └── main.swift
├── swiftMAIL/
│   ├── swiftMAIL
│   ├── logs/
│   └── source_code/
│       └── scm.main.swift
├── swiftBASE/
│   ├── swiftBASE
│   ├── base.json
│   ├── logs/
│   └── source_code/
│       └── scb.main.swift
├── swiftNOTES/
│   ├── swiftNOTES
│   ├── capture_accounts.json
│   ├── logs/
│   └── source_code/
│       ├── scn.main.swift
│       └── notes_capture.py   # shared email/text capture engine (also used by swiftCALENDAR)
├── swiftSTOCKS/
│   ├── swiftSTOCKS
│   ├── logs/
│   └── source_code/
│       └── scs.main.swift
├── swiftSYSINFO/
│   ├── swiftSYSINFO.app
│   ├── swiftSYSINFO
│   ├── Package.swift
│   ├── Info.plist
│   ├── build.sh
│   └── Sources/
│       └── swiftSYSINFO/
│           └── main.swift
├── swiftVAULT/
│   ├── swiftVAULT
│   ├── logs/
│   └── source_code/
│       └── scv.main.swift
├── swiftVIEW/
│   ├── swiftVIEW.app
│   ├── swiftVIEW
│   ├── Package.swift
│   ├── Info.plist
│   ├── build.sh
│   └── Sources/
│       └── swiftVIEW/
│           └── main.swift
├── swiftXLOGO/
│   ├── swiftXLOGO.app
│   ├── swiftXLOGO
│   ├── Package.swift
│   ├── Info.plist
│   ├── build.sh
│   └── Sources/
│       └── swiftXLOGO/
│           └── main.swift
├── Open swiftSUITE (swiftCT).app   # auto-created after Build All Apps — the recommended way in
├── Start Here (swiftADMIN).command # double-click to launch swiftADMIN without touching Terminal
├── README.md
├── LICENSE
└── .gitignore
```
`swiftADMIN` automatically detects whether an app's source lives in `source_code/` or loose at the app root, and builds from whichever it finds — apps don't all need to be migrated to this layout at once.

---
## Web Access via ttyd
> **On the Mac itself?** You probably don't need this section — `swiftCT` (see below) gives you a native app that launches straight into swiftCORE, no browser or ttyd required. ttyd is for reaching the suite from *other* devices — your phone, iPad, or someone else's computer — over your own private network (e.g. [Tailscale](https://tailscale.com)).
ttyd is a small tool that serves a terminal session over HTTP, rendered in your browser using xterm.js. All ANSI colors, box-drawing characters, and keyboard input work correctly.
```bash
# Install ttyd via Homebrew
brew install ttyd
# Start via swiftADMIN (recommended)
python3 swiftADMIN/swiftADMIN.py
# Select [18] Start ttyd — also [19] ttyd Status, [20] Stop ttyd
# Or start manually
ttyd -p 7681 --writable ./swiftCORE/swiftCORE
```
Then open `http://<your-private-network-ip>:7681` in any browser on that network.
> **Security warning:** Never expose the ttyd port to the public internet. Always use Tailscale or another VPN. The `--writable` flag gives full terminal access to whoever connects.

---
## swiftADMIN
`swiftADMIN/swiftADMIN.py` is the administrative toolkit for the suite. It handles building all apps as universal binaries, managing the ttyd web terminal server, exporting data, and resetting the suite to factory defaults. See the [swiftADMIN documentation](docs/swiftADMIN.md) for full details.

---
## swiftCT
`swiftCT` is a native macOS terminal launcher for swiftCORE. Its primary mode is fully local — no browser, no ttyd, no network — spawning swiftCORE as a direct local process. Double-click `swiftCT.app` for a native GUI window with an embedded terminal, or run `./swiftCT` directly from a shell for a zero-frills passthrough straight into swiftCORE. It also includes two optional convenience extras — launching an external Terminal.app window, and connecting to a remote machine over SSH — for anyone who wants them; neither is required or used for normal swiftSUITE operation. See [swiftCT's own README](docs/swiftCT.md) for the full story, including why SSH isn't the primary access method here (short version: Syncthing keeping each machine's data in sync directly turned out to be simpler than one central machine reached over SSH).
It's self-locating: swiftCT finds `swiftCORE` relative to its own position on disk, so the whole `swiftSUITE` folder can be moved, renamed, or copied anywhere and swiftCT still finds its neighbor correctly. It's built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT License — see [swiftCT/THIRD-PARTY-LICENSES.md](swiftCT/THIRD-PARTY-LICENSES.md)), and builds automatically as part of `swiftADMIN`'s Build All Apps. See the [swiftCT documentation](docs/swiftCT.md) for full details.

---
## Utilities
Optional companion apps, launchable directly from swiftCT's Utilities menu (up to 6 configurable slots) or run standalone. These aren't part of the core suite's shared auth or navigation system — they're quick-access desktop extras.
| App | Description |
|-----|-------------|
| swiftEYES | Classic xeyes-style floating companion, tracking your cursor wherever it goes |
| swiftCLOCK | Analog clock — v1 is a clean original design; v2 adds live cursor-tracking eyes and Day-Date-style complications (a date window, and a red Sunday) to the same face |
| swiftSYSINFO | BGInfo-style system telemetry dashboard — hardware info, live CPU/memory/disk/network usage, and VPN/Tailscale/Syncthing status at a glance |
| swiftXLOGO | A personal, nostalgic take on xlogo — a colorful X shape with a genuinely transparent background, floating freely on your desktop |
| swiftVIEW | Read-only glance companion — today's and tomorrow's calendar events, weather, and notes together in one list, with click-through detail popups |
Documentation: [swiftEYES](docs/swiftEYES.md) · [swiftCLOCK](docs/swiftCLOCK.md) · [swiftSYSINFO](docs/swiftSYSINFO.md) · [swiftXLOGO](docs/swiftXLOGO.md) · [swiftVIEW](docs/swiftVIEW.md)
Like swiftCT, all five are Swift Package Manager projects built as universal binaries via their own `build.sh`, and are picked up automatically by `swiftADMIN`'s Build All Apps.

---
## Navigation
Every app shares a consistent nav footer at the bottom of the screen:
```
[B] Base  [C] Calendar  [T] Contacts  [M] Mail  [N] Notes  [S] Stocks  [V] Vault  [L] Logout
```
Press any letter to jump directly to that app. The current app is highlighted in green.

---
## Security Notes
- Notes, Vault, and Contacts use **AES-256-GCM** encryption via Apple's CryptoKit
- The master password is hashed with **SHA-256 + random salt** and stored in `.core_credentials`
- The session key is derived from your password and written to `.core_session` (0600 permissions) for 30 minutes
- This is a **personal project**, not a hardened security tool. The key derivation is simpler than industry-standard PBKDF2. Do not use for highly sensitive data
- ttyd with `--writable` exposes a full terminal — use behind Tailscale or another VPN, never expose to the public internet

---
## Contributing
This started as a personal project. PRs welcome — especially for:
- Additional calendar account types
- Windows/Linux compatibility (currently macOS only)
- F-key navigation — use F1-F7 for suite-wide app switching, eliminating all letter-key conflicts (e.g. C for Calendar, V for Vault, N for Notes). Function keys are currently unused across all apps and would make a clean replacement for the nav footer letter keys

---
## License
MIT — see [LICENSE](LICENSE)
`swiftCT` includes [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza and contributors, also MIT licensed — see [swiftCT/THIRD-PARTY-LICENSES.md](swiftCT/THIRD-PARTY-LICENSES.md) for the full text.

---
## Acknowledgements
Built with AI assistance from Google Gemini (v1.0) and [Claude](https://claude.ai) by Anthropic (v2.0+). The `c` suffix on every version number is a nod to that collaboration.
`swiftCT`'s native terminal rendering is powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), by Miguel de Icaza and contributors.
