# swiftCT

swiftCT is a native macOS terminal launcher for swiftCORE — the entry point
into swiftSUITE. It connects you to the core set of swiftSUITE applications
(swiftCALENDAR, swiftCONTACTS, swiftCORE, swiftMAIL, swiftNOTES, swiftSTOCKS,
and swiftVAULT) with no browser, no ttyd, and no network connection of any
kind — everything runs locally.

## What it does

- Spawns `swiftCORE` as a local process and renders it in a native, embedded
  terminal, using [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  (MIT License — see [swiftCT/THIRD-PARTY-LICENSES.md](../swiftCT/THIRD-PARTY-LICENSES.md))
- Self-locating: rather than a hardcoded path, swiftCT walks upward from
  wherever it's actually running until it finds a sibling `swiftCORE`
  folder — so the whole `swiftSUITE` folder can be moved, renamed, or
  copied anywhere and swiftCT still finds its neighbor correctly
- Works two ways:
  - **Double-click `swiftCT.app`** → opens a native GUI window with the
    embedded terminal
  - **Run `./swiftCT` from a shell** → execs straight into `swiftCORE`
    in-place, no GUI window — behaves exactly like running `swiftCORE`
    directly

## Requirements

swiftCT must live as a sibling folder to `swiftCORE`, inside the same
`swiftSUITE` root as the rest of the suite:

```
swiftSUITE/
├── swiftCT/
├── swiftCORE/
├── swiftCALENDAR/
├── swiftCONTACTS/
├── swiftMAIL/
├── swiftNOTES/
├── swiftSTOCKS/
└── swiftVAULT/
```

`swiftCORE` must already be built — swiftCT doesn't build it for you (see
`swiftADMIN`'s Build All Apps). macOS 12 or later.

## Building

swiftCT builds automatically as part of `swiftADMIN`'s **Build All Apps**,
alongside the other seven apps — nothing extra to do.

To build it standalone:

```bash
cd swiftCT
chmod +x build.sh
./build.sh
```

This produces a universal (Apple Silicon + Intel) binary two ways:
`swiftCT.app` (the GUI app bundle) and a standalone `./swiftCT` binary for
shell use, both landing in the same `swiftCT/` folder.

Building requires Xcode Command Line Tools (`xcode-select --install`) —
full Xcode is *not* required. The universal binary is produced by building
each architecture separately (`swift build --arch arm64` /
`--arch x86_64`) and merging the results with `lipo`, which avoids needing
Xcode's XCBuild — that combined-multi-arch path in modern Swift Package
Manager pulls in a full Xcode dependency that plain Command Line Tools
don't provide.

### App icon

The `swiftCT.iconset` folder is checked into the repo alongside the rest of
swiftCT's source, so the icon is generated automatically — no manual steps
needed. The first time `build.sh` runs, it finds the iconset, generates
`swiftCT.icns` from it via `iconutil`, and bakes it into the app bundle.
Subsequent builds reuse the already-generated `.icns` rather than
regenerating it every time.

If you ever want to change the icon, replace the PNGs inside
`swiftCT.iconset/`, delete the existing `swiftCT.icns`, and rebuild — it'll
regenerate from the new artwork.

## Menu bar features

- **Terminal → Color Theme** — five built-in background presets (Clear
  Dark, Charcoal Gray, Deep Navy, Dark Plum, Black), switchable live
  without rebuilding
- **Terminal → Launch External Terminal** — opens Apple's Terminal.app
  pointed at the swiftSUITE root, for anyone who wants direct filesystem
  access alongside the app
- Standard macOS app menu — About, Hide, Hide Others, Quit — all present
  and working normally, including standard keyboard shortcuts

## Why no SSH?

Earlier development explored an SSH-based variant of this launcher, meant
to connect to a remote Mac acting as the suite's single source of truth
across multiple machines. That approach was dropped in favor of
[Syncthing](https://syncthing.net) keeping the whole `swiftSUITE` folder
in sync across devices directly — simpler, works offline, and avoids SSH
key management entirely. swiftCT reflects that decision: it's intentionally
local-only, with no networking code at all.

## Permissions note

The first time you launch swiftCT, macOS may prompt for permission to
access files in your Documents folder (since `swiftSUITE` typically lives
there, and swiftCT needs to read the `swiftCORE` binary). This is a one-time
prompt — `build.sh` code-signs the app bundle (ad-hoc) specifically so
macOS remembers your answer between launches. You'll only see the prompt
again after rebuilding, since a rebuild produces a new binary signature.

## License

MIT, consistent with the rest of swiftSUITE. Includes
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), also MIT licensed
— see [swiftCT/THIRD-PARTY-LICENSES.md](../swiftCT/THIRD-PARTY-LICENSES.md)
for the full text.
