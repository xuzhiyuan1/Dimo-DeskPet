#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/迪莫桌宠.app"
CONTENTS_DIR="$APP_DIR/Contents"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$PROJECT_DIR/dist"

xcrun swiftc \
  -O \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos13.0 \
  -parse-as-library \
  "$PROJECT_DIR/macOS/Sources/main.swift" \
  -o "$CONTENTS_DIR/MacOS/DimoPet" \
  -framework AppKit \
  -framework SwiftUI

cp "$PROJECT_DIR/macOS/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/macOS/Resources/dimo-watercolor.png" "$CONTENTS_DIR/Resources/dimo-watercolor.png"
cp "$PROJECT_DIR/macOS/Resources/DimoPet.icns" "$CONTENTS_DIR/Resources/DimoPet.icns"
chmod 755 "$CONTENTS_DIR/MacOS/DimoPet"

codesign --force --deep --sign - "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP_DIR" \
  "$PROJECT_DIR/dist/迪莫桌宠-1.0-macOS-arm64.zip"

echo "构建完成：$APP_DIR"
