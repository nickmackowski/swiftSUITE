# swiftSYSINFO

A BGInfo-style system telemetry dashboard — a small floating panel showing hardware info, live resource usage, and network/sync/VPN status at a glance.

---

## What It Shows

**Hardware & system**
- System (hostname), Model (name + identifier, e.g. "MacBook Pro (18,2)"), Chip, Total Memory, OS Version, Uptime, Local IP

**Live resource usage**
- CPU, Memory, and Disk usage bars
- Any additional mounted local or network volumes, each with their own usage bar
- Network — a bidirectional up/down rate bar

**Status rows** (each with a colored stoplight dot)
- **VPN** — green if any configured Apple VPN profile (System Settings → Network → VPN) is currently connected. Filtered to exclude Tailscale specifically, which also registers itself as a VPN-type service at the OS level — without this filter, this row would just duplicate the Tailscale row below rather than showing genuinely separate VPN status.
- **Tailscale** — 3-state: Connected (green), Starting (yellow), Not Connected (red)
- **Syncthing** — supports multiple folder IDs; status reflects whichever configured folder is *least* caught up, not just the first one checked, so a single green light genuinely means everything is synced, not just one folder among several
- **Battery** — 3-state charge level (red under 30%, yellow 30–70%, green above), plus a separate "Charging" indicator in green text when plugged in and charging

Each of VPN, Tailscale, and Syncthing can be individually shown or hidden via checkboxes in swiftCT's **Settings → Services** — useful if you don't use one or more of these.

---

## Refresh Rates

Two independent timers, tuned for battery/energy impact:

- **Network** refreshes every 2 seconds — the only stat where a livelier feel is actually worth it, since a rate bar reads as broken if it updates sluggishly.
- **Everything else** (CPU, Memory, Disk, Uptime, VPN, Tailscale, Syncthing, Battery) refreshes every 20 seconds. None of these benefit meaningfully from tighter granularity on a glanceable dashboard, and each check costs a real subprocess spawn or network request — running them every 2 seconds like the network check does was enough sustained background activity for macOS to flag swiftSYSINFO under "Using Significant Energy." The VPN, Tailscale, and Syncthing checks are also skipped entirely on cycles where their row is hidden in Settings, rather than paying the cost for a row that isn't even displayed.

---

## Right-Click Menu

- **Bigger / Smaller** — unlike swiftEYES and swiftCLOCK, this rebuilds the entire window from scratch at a new scale factor rather than simply resizing it. The dashboard's rows are laid out with absolute positions computed once (not continuously recalculated from the view's bounds the way a face or a pair of eyes are), so "bigger" here means tearing down and reconstructing every row at new, scaled coordinates — same end result for you, different mechanism under the hood.
- **Reverse Colors** — toggles light/dark styling
- **Quit**

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)
- A Syncthing and/or Tailscale installation, only if you want those specific status rows populated — both degrade gracefully to "Not Configured" otherwise

---

## Configuration

Syncthing API key, folder ID(s), Tailscale binary path, and the show/hide toggles for VPN/Tailscale/Syncthing all live in swiftCT's **Settings → Services**, not in swiftSYSINFO itself — see [swiftCT's documentation](swiftCT.md#services-syncthing--tailscale--vpn) for details. Both apps read from the same shared config file (`swiftCT/swiftsuite-config.json`).

---

## Building

Swift Package Manager project, built as a universal binary (arm64 + x86_64) via its own `build.sh`:

```bash
cd swiftSYSINFO
./build.sh
```

Or via swiftADMIN (auto-detected by the presence of `Package.swift`):

```bash
cd swiftADMIN
python3 swiftADMIN.py
# Select [1] Build All Apps, or [2] to build swiftSYSINFO specifically
```

---

Part of the [swiftSUITE](../README.md) collection. Launchable directly from [swiftCT](swiftCT.md)'s Utilities menu.
