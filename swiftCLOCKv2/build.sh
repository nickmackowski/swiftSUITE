#!/bin/bash
set -e

APP_NAME="swiftCLOCKv2"
BUNDLE="${APP_NAME}.app"
BIN_NAME="swiftCLOCKv2"

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

ARM64_BIN=$(find .build-arm64 -type f -name "$BIN_NAME" -path "*release*" -not -path "*.dSYM*" | head -n 1)
X86_BIN=$(find .build-x86_64 -type f -name "$BIN_NAME" -path "*release*" -not -path "*.dSYM*" | head -n 1)

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
chmod +x "$BUNDLE/Contents/MacOS/$BIN_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"

if [ -d "${APP_NAME}.iconset" ] && [ ! -f "${APP_NAME}.icns" ]; then
    echo "Generating icon from ${APP_NAME}.iconset..."
    iconutil -c icns "${APP_NAME}.iconset"
fi

if [ -f "${APP_NAME}.icns" ]; then
    cp "${APP_NAME}.icns" "$BUNDLE/Contents/Resources/${APP_NAME}.icns"
    echo "Icon added."
else
    echo "NOTE: no ${APP_NAME}.icns or ${APP_NAME}.iconset found — app will use the generic icon."
fi

# Ad-hoc code sign so macOS remembers permission grants between launches
# instead of re-prompting every time.
echo "Code signing..."
codesign --force --deep --sign - "$BUNDLE"

cp "$BUNDLE/Contents/MacOS/$BIN_NAME" "./$BIN_NAME"
chmod +x "./$BIN_NAME"

echo "Verifying architectures..."
lipo -info "$BUNDLE/Contents/MacOS/$BIN_NAME"

echo ""
echo "Done."
echo "  GUI:  open $BUNDLE"
echo ""
echo "This build runs on both Apple Silicon and Intel Macs."
