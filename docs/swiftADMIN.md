# swiftADMIN

swiftADMIN is a Python-based administrative toolkit for the swiftSUITE. It handles building the Swift apps, managing the ttyd web terminal server, and performing maintenance tasks like factory reset.

---

## What It Does

- Builds all seven Swift apps as universal binaries (x86_64 + arm64 via lipo)
- Manages ttyd — start, check status, and stop the web terminal server
- Exports suite data for backup purposes
- Resets the suite to factory defaults for sharing or fresh starts
- Provides a home for future admin features (password change coming in v3.0)

---

## Running swiftADMIN

```bash
cd swiftSUITE/swiftADMIN
python3 swiftADMIN.py
```

The script auto-detects the suite root from its own location and changes directory accordingly. You can also run it from any directory:

```bash
python3 /path/to/swiftSUITE/swiftADMIN/swiftADMIN.py
```

---

## Requirements

```bash
pip3 install rich cryptography
```

---

## Main Menu

```
── BUILD ──────────────────────────────
[1]  Build All Apps
[2]  Build Single App

── SECURITY ────────────────────────────
[3]  Change Master Password    ← Coming in v3.0

── DATA ────────────────────────────────
[4]  Export All Data
[5]  Import Data

── TTYD WEB TERMINAL ───────────────────
[6]  Start ttyd
[7]  ttyd Status
[8]  Stop ttyd

── DANGER ZONE ─────────────────────────
[9]  Reset to Factory Defaults

[Q]  Quit
```

---

## Build All Apps `[1]`

Compiles all seven Swift apps as universal binaries supporting both Apple Silicon (arm64) and Intel (x86_64) Macs.

- Builds run in parallel using all available CPU cores
- A live progress display shows each app's build status
- Build logs are saved to `swiftLOGS/<AppName>/` with up to 5 logs per app
- A macOS notification is sent when the build completes
- Binary sizes are shown in the summary

Requires Xcode Command Line Tools (`xcode-select --install`).

---

## Build Single App `[2]`

Same as Build All but presents a numbered menu to select a single app. Useful for quick rebuilds after editing one source file.

---

## Change Master Password `[3]`

**Coming in v3.0.**

The password change feature is under development. Changing the master password requires re-encrypting all data in swiftNOTES, swiftVAULT, and swiftCONTACTS with a new key. Until full re-encryption is implemented, use the export/import workflow as a workaround:

1. Export data from each app's Utilities menu
2. Run factory reset
3. Log in with new password
4. Re-import data via each app's Utilities menu
5. Warning: This feature is currently under development. Data loss is possible (or even likely). Proceed with caution and ensure you have backups before continuing.

---

## Export All Data `[4]`

Scans all app folders and collects any exportable files (CSV exports, JSON backups) into a timestamped folder:

```
swiftSUITE/swiftADMIN_export_20260717_092143/
```

Note: encrypted data files can only be exported as plaintext by using each app's individual Utilities → Export CSV Template option first. This function collects files that have already been exported.

---

## Start ttyd `[6]`

Launches ttyd as a background process serving swiftCORE in a browser.

- Prompts for port (default 7681)
- Saves the process PID to `.swiftadmin/ttyd.pid`
- Automatically finds the swiftCORE binary

After starting, open `http://<your-tailscale-ip>:7681` in any browser.

> **Security:** Always use Tailscale or another VPN. Never expose ttyd to the public internet.

---

## ttyd Status `[7]`

Shows whether ttyd is currently running, the PID, configured port, and process uptime.

---

## Stop ttyd `[8]`

Sends SIGTERM to the ttyd process. If the process does not exit cleanly, SIGKILL is sent as a fallback. Cleans up the PID file.

---

## Reset to Factory Defaults `[9]`

Permanently deletes all personal data from the suite and returns it to a clean state ready for first-time setup.

**What is deleted:**
- swiftCORE login credentials and session
- All notes, vault credentials, and contacts
- Mail account configurations
- Stocks portfolio data
- Calendar sync data and account configurations
- All session and backup files
- Build logs (swiftLOGS/)
- swiftADMIN configuration

**What is kept:**
- All compiled Swift binaries
- All source `.swift` files
- `swiftADMIN.py` and `calendar_sync.py`

**Confirmation required:** You must type `RESET` exactly (case-sensitive) to proceed. This cannot be undone.

This feature is designed for sharing the suite with others — run factory reset on a copy of the suite directory before uploading to GitHub or handing off to a colleague.

---

## Configuration

swiftADMIN stores its configuration in `.swiftadmin/config.json`:

```json
{
  "ttyd_port": 7681,
  "ttyd_bind": "0.0.0.0"
}
```

This file is created automatically on first run and can be edited manually if needed.

---

## Tips

- Run `[1] Build All` after pulling updates from GitHub to recompile all apps
- Use `[9] Factory Reset` on a copy of the directory before sharing — never on your live suite
- The build log files in `swiftLOGS/` are invaluable for debugging compile errors
