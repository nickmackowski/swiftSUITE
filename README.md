# swiftSUITE

A personal productivity suite built entirely in Swift for macOS terminals. Seven compiled command-line apps sharing a unified login, consistent visual design, and keyboard navigation — accessible locally or from any browser on your network via [ttyd](https://github.com/tsl0922/ttyd) and Tailscale, or through swiftCT, a native local launcher (see below). 

Beta Notice: This software is currently in development. While it is functional, you may encounter bugs, glitches, unexpected behavior, or incomplete features. If the application becomes unresponsive or behaves unexpectedly, pressing Ctrl+Z and restarting swiftCORE may be enough to zap "the ghost in the machine." Please use this software with caution, report any issues you encounter, and always keep backups of your data.  Thanks and enjoy ;-)

<img width="2314" height="1688" alt="image" src="https://github.com/user-attachments/assets/f57ff977-f6b1-41da-9a9e-7193156111a6" />


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
| swiftCT | `swiftCT` | Terminal Launcher for swiftCORE |

`swiftADMIN` is a companion tool — a Python toolkit (not a compiled Swift binary) for building, ttyd management, and factory reset.

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
- [swiftADMIN](docs/swiftADMIN.md)
- [swiftCT](docs/swiftCT.md)

---

## Features

- **Unified auth** — log in once via swiftCORE; Notes, Vault, and Contacts unlock automatically for 30 minutes
- **120-column design system** — rounded box UI, greenbar grids, alphabetical nav footer across all apps
- **AES-256-GCM encryption** — Notes, Vault, and Contacts data encrypted at rest
- **Live navigation** — single-key jumps between all apps via `execv`, no launcher round-trips
- **Web accessible** — serve the full suite in any browser via ttyd + Tailscale
- **Native local launcher** — swiftCT drops you straight into swiftCORE with a native macOS app, no browser or ttyd required; double-click for a GUI window, or run it directly from a shell
- **Aviation weather** — one combined setup in swiftCALENDAR creates both a live METAR (current conditions) and TAF (forecast) account from a single airport code, with the real airport name and city decoded in the detail view
- **ICS calendar sync** — supports any CalDAV/ICS feed (iCloud, Outlook, Google Calendar)
- **Calendar overlays** — birthdays (from swiftCONTACTS) and due-date reminders (from swiftNOTES) appear automatically on swiftCALENDAR's month view, computed live on every launch — nothing is duplicated or stored twice
- **Remote capture** — email or text a note (or a real calendar event) to a dedicated inbox from anywhere, and it shows up automatically the next time swiftNOTES or swiftCALENDAR opens; swiftNOTES supports more than one capture inbox at once
- **15-minute auto-sync** — swiftMAIL polls in the background without requiring manual refresh
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

```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps
```

Or build manually:

```bash
cd swiftCORE
swiftc -target arm64-apple-macosx14.0 scl.main.swift -o swiftCORE_arm64
swiftc -target x86_64-apple-macosx14.0 scl.main.swift -o swiftCORE_x86
lipo -create swiftCORE_arm64 swiftCORE_x86 -output swiftCORE
```

Repeat for each app directory. If an app's source has been moved into its own `source_code/` subfolder (see Directory Structure below), adjust the path in the `swiftc` command accordingly — `swiftADMIN` handles this automatically either way.

> **Note:** `swiftCT` builds differently from the seven core apps above — it's a Swift Package Manager project, not a single `.main.swift` file compiled directly via `swiftc`. `swiftADMIN`'s Build All Apps handles this automatically by running swiftCT's own `build.sh`, which produces both a native `.app` bundle and a standalone CLI binary. See [docs/swiftCT.md](docs/swiftCT.md) for details, or build it manually with `cd swiftCT && ./build.sh`.

### 3. First launch

```bash
cd swiftCORE
./swiftCORE
```

On first run, swiftCORE prompts you to create a username and password. This password encrypts your Notes, Vault, and Contacts data.

<img width="2314" height="1688" alt="image" src="https://github.com/user-attachments/assets/f07241c1-f696-4a40-98a7-f26df76b2b79" />

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
│   └── Sources/
│       └── swiftCT/
│           └── main.swift
├── swiftMAIL/
│   ├── swiftMAIL
│   ├── logs/
│   └── source_code/
│       └── scm.main.swift
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
├── swiftVAULT/
│   ├── swiftVAULT
│   ├── logs/
│   └── source_code/
│       └── scv.main.swift
├── README.md
├── LICENSE
└── .gitignore
```

`swiftADMIN` automatically detects whether an app's source lives in `source_code/` or loose at the app root, and builds from whichever it finds — apps don't all need to be migrated to this layout at once.

---


## Web Access via ttyd

> **On the Mac itself?** You probably don't need this section — `swiftCT` (see below) gives you a native app that launches straight into swiftCORE, no browser or ttyd required. ttyd is for reaching the suite from *other* devices — your phone, iPad, or someone else's computer — over your Tailscale network.

### What is Homebrew?

Homebrew is the most widely used package manager for macOS. It lets you install command-line tools with a single command. If you do not have Homebrew installed:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

This only needs to be done once. Homebrew will also install Xcode Command Line Tools if they are not already present.

### What is Tailscale?

Tailscale is a zero-configuration VPN that creates a private encrypted network between your devices. Once installed on your Mac and any other device (iPhone, iPad, another computer), those devices can reach each other securely over the internet as if they were on the same local network — without opening any ports on your router or exposing anything to the public internet. It is free for personal use.

swiftSUITE running on a home Mac can be accessed securely from anywhere in the world using Tailscale, with no additional configuration required.

### Installing and Running ttyd

ttyd is a tool that serves a terminal session over HTTP, rendered in your browser using xterm.js. All ANSI colors, box-drawing characters, and keyboard input work correctly.

```bash
# Install ttyd via Homebrew
brew install ttyd

# Start via swiftADMIN (recommended)
python3 swiftADMIN/swiftADMIN.py
# Select [6] Start ttyd

# Or start manually
ttyd -p 7681 --writable ./swiftCORE/swiftCORE
```

Then open `http://<your-tailscale-ip>:7681` in any browser on your Tailscale network.

> **Security warning:** Never expose the ttyd port to the public internet. Always use Tailscale or another VPN. The `--writable` flag gives full terminal access to whoever connects.

---

## swiftADMIN

`swiftADMIN/swiftADMIN.py` is the administrative toolkit for the suite. It handles building all apps as universal binaries, managing the ttyd web terminal server, exporting data, and resetting the suite to factory defaults. See the [swiftADMIN documentation](docs/swiftADMIN.md) for full details.

---

## swiftCT

`swiftCT` is a native macOS terminal launcher for swiftCORE. Its primary mode is fully local — no browser, no ttyd, no network — spawning swiftCORE as a direct local process. Double-click `swiftCT.app` for a native GUI window with an embedded terminal, or run `./swiftCT` directly from a shell for a zero-frills passthrough straight into swiftCORE. It also includes two optional convenience extras — launching an external Terminal.app window, and connecting to a remote machine over SSH — for anyone who wants them; neither is required or used for normal swiftSUITE operation. See [swiftCT's own README](docs/swiftCT.md) for the full story, including why SSH isn't the primary access method here (short version: Syncthing keeping each machine's data in sync directly turned out to be simpler than one central machine reached over SSH).

It's self-locating: swiftCT finds `swiftCORE` relative to its own position on disk, so the whole `swiftSUITE` folder can be moved, renamed, or copied anywhere and swiftCT still finds its neighbor correctly. It's built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT License — see [swiftCT/THIRD-PARTY-LICENSES.md](swiftCT/THIRD-PARTY-LICENSES.md)), and builds automatically as part of `swiftADMIN`'s Build All Apps. See the [swiftCT documentation](docs/swiftCT.md) for full details.

---

## Navigation

Every app shares a consistent nav footer at the bottom of the screen:

```
[T] Contacts  [C] Calendar  [M] Mail  [N] Notes  [S] Stocks  [V] Vault  [L] Logout
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

## Roadmap

**v3.0 (current) — Complete ✅**

A coordinated, suite-wide release: consistent header styling and versioning across every app, directory/log restructuring, and real new features — swiftNOTES gained remote email/text capture (with multi-account support), and swiftCALENDAR gained live birthday and due-date overlays, the combined aviation weather setup, and remote calendar entries sharing swiftNOTES' own capture pipeline. See each app's own documentation for full details.

**v4.0 (planned)**
- Seamless password change with full data re-encryption
- F-key navigation — use F1-F7 for suite-wide app switching, eliminating all letter-key conflicts (e.g. C for Calendar, V for Vault, N for Notes). Function keys are currently unused across all apps and would make a clean replacement for the nav footer letter keys

**Deliberately not planned**
- Two-way calendar sync (pushing locally created events back to iCloud, Outlook, or Google Calendar) was considered and explicitly ruled out. swiftCALENDAR is meant to stay a quick-glance overlay tool, not a full calendar replacement — it remains read-only against external feeds by design.

---

## Contributing

This started as a personal project. PRs welcome — especially for:
- Additional calendar account types
- Windows/Linux compatibility (currently macOS only)

---

## License

MIT — see [LICENSE](LICENSE)

`swiftCT` includes [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza and contributors, also MIT licensed — see [swiftCT/THIRD-PARTY-LICENSES.md](swiftCT/THIRD-PARTY-LICENSES.md) for the full text.

---

## Acknowledgements

Built with AI assistance from Google Gemini (v1.0) and [Claude](https://claude.ai) by Anthropic (v2.0+). The `c` suffix on every version number is a nod to that collaboration.

`swiftCT`'s native terminal rendering is powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), by Miguel de Icaza and contributors.
