#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h:h}"
SOURCE_DIR="$PROJECT_DIR/assets/app-source/macOS"
VERSION_FILE="$PROJECT_DIR/assets/versioning/VERSION"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
BUILD_DIR="$(mktemp -d /tmp/dimo-pet-build.XXXXXX)"
APP_DIR="$BUILD_DIR/迪莫桌宠.app"
CONTENTS_DIR="$APP_DIR/Contents"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

xcrun swiftc \
  -O \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos13.0 \
  -parse-as-library \
  "$SOURCE_DIR/Sources/main.swift" \
  -o "$CONTENTS_DIR/MacOS/DimoPet" \
  -framework AppKit \
  -framework SwiftUI

cp "$SOURCE_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SOURCE_DIR/Resources/dimo-watercolor.png" "$CONTENTS_DIR/Resources/dimo-watercolor.png"
cp "$SOURCE_DIR/Resources/DimoPet.icns" "$CONTENTS_DIR/Resources/DimoPet.icns"
chmod 755 "$CONTENTS_DIR/MacOS/DimoPet"

codesign --force --deep --sign - "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP_DIR" \
  "$PROJECT_DIR/Dimo-DeskPet-${VERSION}-macOS-arm64.zip"

echo "构建完成：$PROJECT_DIR/Dimo-DeskPet-${VERSION}-macOS-arm64.zip"
