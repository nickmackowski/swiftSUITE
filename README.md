# swiftSUITE

A personal productivity suite built entirely in Swift for macOS terminals. Six compiled command-line apps sharing a unified login, consistent visual design, and keyboard navigation — accessible locally or from any browser on your network via [ttyd](https://github.com/tsl0922/ttyd) and Tailscale. Beta Notice: This software is currently in development. While it is functional, you may encounter bugs, glitches, unexpected behavior, or incomplete features. If the application becomes unresponsive or behaves unexpectedly, pressing Ctrl+Z and restarting swiftCORE may be enough to zap "the ghost in the machine." Please use this software with caution, report any issues you encounter, and always keep backups of your data.  Thanks and enjoy ;-)

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/8cc305cc-9012-4773-87b9-1a59ca33fe44" />

## The Story Behind This Project

Version 1.0 of swiftSUITE was developed with the assistance of Google Gemini. Version 2.0 was significantly refined, expanded, and rebuilt with the assistance of Anthropic Claude. The `c` suffix on every version number is a small nod to that collaboration. Version numbers are derived from the date of the most recent compile. If you modify the source code, please preserve the existing versioning convention. All applications use the v2.5.MM.DD versioning format, where MM is the month and DD is the day of the release. The exception is swiftCALENDAR, which is currently version v2.7 due to several late-stage, semi-major changes introduced during development.

I am not a professional programmer or software developer. This project is a demonstration of what becomes possible when a idea and AI-assistance development come together. If you have an idea for a personal tool and think you lack the technical background to build it — this project is proof that you might be wrong. 

Fun Fact: Claude AI even helped write this README and most of the supporting documentation ;-) Like the rest of the project, it's not perfect—but hopefully it's useful. If you spot anything that needs improvement, feel free to update it.  Thanks and have a great day!

---

## Apps

| App | Binary | Description |
|-----|--------|-------------|
| swiftCORE | `swiftCORE` | Launcher and authentication hub |
| swiftSTOCKS | `swiftSTOCKS` | Portfolio tracker with live market data |
| swiftNOTES | `swiftNOTES` | AES-256 encrypted notebook with archive |
| swiftVAULT | `swiftVAULT` | AES-256 encrypted password manager |
| swiftCONTACTS | `swiftCONTACTS` | Encrypted contact book |
| swiftCALENDAR | `swiftCALENDAR` | Calendar with ICS, METAR, and TAF support |
| swiftMAIL | `swiftMAIL` | IMAP/SMTP email client |

---

## Documentation

Detailed setup and usage guides for each app:

- [swiftCORE](docs/swiftCORE.md) — Launcher and authentication
- [swiftNOTES](docs/swiftNOTES.md) — Encrypted notebook
- [swiftVAULT](docs/swiftVAULT.md) — Password manager
- [swiftCONTACTS](docs/swiftCONTACTS.md) — Contact manager
- [swiftSTOCKS](docs/swiftSTOCKS.md) — Portfolio tracker
- [swiftCALENDAR](docs/swiftCALENDAR.md) — Calendar and aviation weather
- [swiftMAIL](docs/swiftMAIL.md) — Email client
- [swiftADMIN](docs/swiftADMIN.md) — Admin toolkit

---

## Features

- **Unified auth** — log in once via swiftCORE; Notes, Vault, and Contacts unlock automatically for 30 minutes
- **120-column design system** — rounded box UI, greenbar grids, alphabetical nav footer across all apps
- **AES-256-GCM encryption** — Notes, Vault, and Contacts data encrypted at rest
- **Live navigation** — single-key jumps between all apps via `execv`, no launcher round-trips
- **Web accessible** — serve the full suite in any browser via ttyd + Tailscale
- **Aviation weather** — METAR and TAF account types in swiftCALENDAR with live NOAA data
- **ICS calendar sync** — supports any CalDAV/ICS feed (iCloud, Outlook, Google Calendar)
- **15-minute auto-sync** — swiftMAIL polls in the background without requiring manual refresh
- **swiftADMIN** — Python toolkit for building, ttyd management, and factory reset

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools
  ```bash
  xcode-select --install
  ```
- Python 3.9+ (for `calendar_sync.py` and `swiftADMIN.py`)
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

Repeat for each app directory.

### 3. First launch

```bash
cd swiftCORE
./swiftCORE
```

On first run, swiftCORE prompts you to create a username and password. This password encrypts your Notes, Vault, and Contacts data.

---

## Directory Structure

```
swiftSUITE/
├── swiftADMIN/
│   └── swiftADMIN.py          # Build, ttyd, and admin toolkit
├── swiftCALENDAR/
│   ├── sccm.main.swift
│   └── calendar_sync.py       # ICS / METAR / TAF sync engine
├── swiftCONTACTS/
│   └── scc.main.swift
├── swiftCORE/
│   └── scl.main.swift
├── swiftMAIL/
│   └── scm.main.swift
├── swiftNOTES/
│   └── scn.main.swift
├── swiftSTOCKS/
│   └── scs.main.swift
├── swiftVAULT/
│   └── scv.main.swift
├── README.md
├── LICENSE
└── .gitignore
```

---


## Web Access via ttyd

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

**v2.7 (current) — Complete ✅**

All v2.7 features shipped. See the [documentation](docs/) for full details on what was built.

**v3.0 (planned)**
- Seamless password change with full data re-encryption
- Two-way calendar sync — push locally created events back to iCloud, Outlook, and Google Calendar
- F-key navigation — use F1-F7 for suite-wide app switching, eliminating all letter-key conflicts (e.g. C for Calendar, V for Vault, N for Notes). Function keys are currently unused across all apps and would make a clean replacement for the nav footer letter keys

---

## Contributing

This started as a personal project. PRs welcome — especially for:
- Additional calendar account types
- swiftMAIL folder management improvements
- Windows/Linux compatibility (currently macOS only)

---

## License

MIT — see [LICENSE](LICENSE)

---

## Acknowledgements

Built with AI assistance from Google Gemini (v1.0) and [Claude](https://claude.ai) by Anthropic (v2.0+). The `c` suffix on every version number is a nod to that collaboration.
