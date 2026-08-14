#!/bin/bash
set -e

APP_NAME="swiftXLOGO"
BUNDLE="${APP_NAME}.app"

rm -rf .build-arm64 .build-x86_64 .build

echo "Building arm64 slice..."
echo "Building for production..."
swift build -c release --arch arm64 --scratch-path .build-arm64

echo "Building x86_64 slice..."
echo "Building for production..."
swift build -c release --arch x86_64 --scratch-path .build-x86_64

# -not -path "*.dSYM*" is required here -- without it, this can match the
# binary's dSYM companion file instead of the real executable, producing
# an "exec format error" when the app tries to launch.
ARM64_BIN=$(find .build-arm64 -type f -name "$APP_NAME" -path "*release*" -not -path "*.dSYM*" | head -n 1)
X86_BIN=$(find .build-x86_64 -type f -name "$APP_NAME" -path "*release*" -not -path "*.dSYM*" | head -n 1)

if [ -z "$ARM64_BIN" ] || [ -z "$X86_BIN" ]; then
    echo "Could not locate one or both built binaries."
    echo "arm64 found: ${ARM64_BIN:-<none>}"
    echo "x86_64 found: ${X86_BIN:-<none>}"
    exit 1
fi

echo "Merging into universal binary with lipo..."
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
lipo -create "$ARM64_BIN" "$X86_BIN" -output "$BUNDLE/Contents/MacOS/$APP_NAME"

# lipo doesn't reliably preserve the execute bit on its output -- without
# this, macOS refuses to launch the bundle at all.
chmod +x "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BUNDLE/Contents/MacOS/$APP_NAME" "./$APP_NAME"
chmod +x "./$APP_NAME"

cp Info.plist "$BUNDLE/Contents/Info.plist"

# Generate the .icns from the iconset if one's present and hasn't been
# built yet -- drop swiftXLOGO.iconset/ next to this script and it's
# picked up automatically.
if [ -d "${APP_NAME}.iconset" ] && [ ! -f "${APP_NAME}.icns" ]; then
    echo "Icon added."
    iconutil -c icns "${APP_NAME}.iconset" -o "${APP_NAME}.icns"
fi
if [ -f "${APP_NAME}.icns" ]; then
    cp "${APP_NAME}.icns" "$BUNDLE/Contents/Resources/${APP_NAME}.icns"
fi

echo "Code signing..."
if [ -d "$BUNDLE" ] && codesign -dv "$BUNDLE" &>/dev/null; then
    echo "$BUNDLE: replacing existing signature"
fi
codesign --force --deep --sign - "$BUNDLE"

echo "Verifying architectures..."
echo "Architectures in the fat file: $BUNDLE/Contents/MacOS/$APP_NAME are:"
lipo -info "$BUNDLE/Contents/MacOS/$APP_NAME"

echo ""
echo "Done."
echo "GUI:   open $BUNDLE"
echo ""
echo "This build runs on both Apple Silicon and Intel Macs."
