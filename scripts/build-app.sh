#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

BUILD_DIR="$ROOT_DIR/.build/nopilote-app"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swiftpm-cache"
swift build -c release --scratch-path "$BUILD_DIR"

APP_DIR="$ROOT_DIR/dist/Nopilote.app"
CONTENTS_DIR="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BUILD_DIR/release/Nopilote" "$CONTENTS_DIR/MacOS/Nopilote"
cp "$ROOT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"
xcrun actool "$ROOT_DIR/AppBundle/Assets.xcassets" \
    --compile "$CONTENTS_DIR/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$CONTENTS_DIR/IconInfo.plist"
cp "$CONTENTS_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/Nopilote.icns"
rm -f "$CONTENTS_DIR/IconInfo.plist"
codesign --force --deep --entitlements "$ROOT_DIR/AppBundle/Nopilote.entitlements" --sign - "$APP_DIR"

print "Built $APP_DIR"
