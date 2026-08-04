#!/bin/bash
set -e

APP_NAME="swiftCT"
BUNDLE="${APP_NAME}.app"
BIN_NAME="swiftCT"

# Always start from clean scratch directories. Swift's module cache bakes
# in the absolute filesystem path at compile time -- if these folders ever
# get carried over between machines (via git, Syncthing, etc.) with a
# different absolute path than where they were built, the compiler fails
# with a "module cache path mismatch" error. Wiping them first guarantees
# every build reflects wherever this actually is right now.
rm -rf .build-arm64 .build-x86_64 .build

echo "Building arm64 slice..."
swift build -c release --arch arm64 --scratch-path .build-arm64

echo "Building x86_64 slice..."
swift build -c release --arch x86_64 --scratch-path .build-x86_64

ARM64_BIN=$(find .build-arm64 -type f -name "$BIN_NAME" -path "*release*" | head -n 1)
X86_BIN=$(find .build-x86_64 -type f -name "$BIN_NAME" -path "*release*" | head -n 1)

if [ -z "$ARM64_BIN" ] || [ -z "$X86_BIN" ]; then
    echo "Could not locate one or both built binaries."
    echo "arm64 found: ${ARM64_BIN:-<none>}"
    echo "x86_64 found: ${X86_BIN:-<none>}"
    exit 1
fi

echo "Merging into universal binary with lipo..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
lipo -create "$ARM64_BIN" "$X86_BIN" -output "$BUNDLE/Contents/MacOS/$BIN_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# Auto-generate swiftCT.icns from swiftCT.iconset if the iconset is present
# but the .icns hasn't been built yet — no manual iconutil step needed.
if [ -d "swiftCT.iconset" ] && [ ! -f "swiftCT.icns" ]; then
    echo "Generating icon from swiftCT.iconset..."
    iconutil -c icns swiftCT.iconset
fi

if [ -f "swiftCT.icns" ]; then
    cp swiftCT.icns "$BUNDLE/Contents/Resources/swiftCT.icns"
    echo "Icon added."
else
    echo "NOTE: no swiftCT.icns or swiftCT.iconset found — app will use the generic icon."
    echo "  Unzip swiftCT.iconset.zip into this folder and rebuild to add it automatically."
fi

# Ad-hoc code sign so macOS remembers the Documents-folder access grant
# between launches, instead of re-prompting every time. (Without a stable
# signature, TCC has no reliable identity to attach your "Allow" answer to.)
echo "Code signing..."
codesign --force --deep --sign - "$BUNDLE"

# Also drop a standalone copy directly in this folder, so it can be run
# straight from a shell (./swiftCT) without going through the .app bundle.
# main.swift detects this case (no controlling terminal vs. interactive
# terminal) and behaves accordingly — GUI window when double-clicked,
# direct passthrough into swiftCORE when run from a shell.
cp "$BUNDLE/Contents/MacOS/$BIN_NAME" "./$BIN_NAME"
chmod +x "./$BIN_NAME"

echo "Verifying architectures..."
lipo -info "$BUNDLE/Contents/MacOS/$BIN_NAME"

echo ""
echo "Done."
echo "  GUI:  open $BUNDLE"
echo "  CLI:  ./$BIN_NAME"
echo ""
echo "This build runs on both Apple Silicon and Intel Macs."
echo "swiftCT should live as a sibling folder to swiftCORE inside swiftSUITE."