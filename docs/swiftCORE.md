# swiftCORE

swiftCORE is the launcher and authentication hub for the swiftSUITE. It is the first app you interact with on every session and the gateway to all other apps.

You can launch swiftCORE directly from a terminal (`./swiftCORE`), or use `swiftCT` — a native macOS app that opens straight into swiftCORE in an embedded terminal window, no manual `cd`-and-run needed. See [swiftCT's documentation](swiftCT.md) for details.

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/45256bcf-fdf4-4ae8-951a-f6376e555ed2" />

---

## What It Does

- Authenticates your identity with a username and password
- Derives a session key that automatically unlocks swiftNOTES, swiftVAULT, and swiftCONTACTS for 30 minutes
- Displays real-time system telemetry (hostname, uptime, CPU, memory) in the header
- Provides single-key navigation to all seven suite apps

---

## First-Time Setup

On first launch swiftCORE detects that no credentials exist and walks you through creating a username and password. This password is used to:

- Authenticate your login on every session
- Derive the encryption key for swiftNOTES, swiftVAULT, and swiftCONTACTS

**Choose a strong password you will remember.** Changing it later requires the swiftADMIN toolkit.

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/d52e22e7-250f-4e1f-9849-d1c3f55600d8" />

---

## The Login Screen

```
login: _          Password: _
Last login: THU JUL 17 09:21:25 2026
```

Type your username, press Tab or Enter, then type your password. The password field does not echo characters.

On successful login, swiftCORE writes a session key to `.core_session` (valid for 30 minutes) and presents the main navigation screen — a centered banner reading **swiftCORE**, with every letter individually colored as a small nod to it being the launcher for the whole suite.

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/29e97210-1132-4989-b230-bef4228567e1" />

## System Telemetry

The header bar displays live system information pulled directly from macOS at launch and refreshed on each screen render. Hostname and uptime are read from the system via uname and sysctl. CPU usage is calculated from processor load averages. Memory usage is read from the system's memory statistics. All telemetry is read-only — swiftCORE never modifies any system settings. The data is purely for at-a-glance awareness while using the suite.

The header clock updates on keystroke, not continuously — this is a known, deliberate limitation shared across the whole suite (see each app's own README for details if relevant).

---

## Navigation

From the main screen, press a single key to jump to any app:

| Key | App |
|-----|-----|
| `T` | swiftCONTACTS |
| `C` | swiftCALENDAR |
| `M` | swiftMAIL |
| `N` | swiftNOTES |
| `S` | swiftSTOCKS |
| `V` | swiftVAULT |
| `L` | Logout |

The nav footer appears at the bottom of every screen in every app, so you can jump between apps at any time without returning to swiftCORE. Each app's own header always shows its name in a solid accent color, with `swift` in plain white — a consistent visual identity across the whole suite. swiftCORE is the one exception, with every letter of its own name individually colored, marking it as the launcher.

---

## Session and Logout

- The session expires after **30 minutes of inactivity**
- Any keypress in any app resets the 30-minute timer
- Pressing `[L] Logout` from any app returns you to swiftCORE and ends the session
- swiftNOTES, swiftVAULT, and swiftCONTACTS will require a new login if the session has expired

---

## Changing Your Password

Password change is handled by **swiftADMIN**. As of this writing, that feature is still under active development — see [swiftADMIN's README](swiftADMIN.md) for its current status and the export/import workaround in the meantime. Note that changing your password invalidates all encrypted app data — export first if needed.
