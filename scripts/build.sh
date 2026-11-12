#!/bin/bash
# Build Temani.app dari Sources/Temani/*.swift
# Syarat: Xcode Command Line Tools  →  xcode-select --install
# Opsi:   ARCH=universal ./scripts/build.sh   (arm64 + x86_64, dipakai di GitHub Actions)
set -e
cd "$(dirname "$0")/.."

APP="build/Temani.app"
SRC=(Sources/Temani/*.swift)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compile..."
if [ "${ARCH:-}" = "universal" ]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos13.0  "${SRC[@]}" -o build/Temani-arm64
  swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "${SRC[@]}" -o build/Temani-x86_64
  lipo -create build/Temani-arm64 build/Temani-x86_64 -output "$APP/Contents/MacOS/Temani"
  rm -f build/Temani-arm64 build/Temani-x86_64
else
  swiftc -O -swift-version 5 "${SRC[@]}" -o "$APP/Contents/MacOS/Temani"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▶ Codesign (ad-hoc)..."
codesign --force --sign - "$APP"

echo "✅ Selesai: $APP"
echo "   Pasang:  cp -R $APP /Applications/ && open /Applications/Temani.app"
