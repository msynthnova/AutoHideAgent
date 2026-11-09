#!/bin/zsh
set -euo pipefail

# Usage:
#   ./bundle.sh            # Debug build & bundle
#   ./bundle.sh release    # Optimized Release build, bundle, and dist/AutoHideAgent-macOS-v1.0.0.zip

MODE="${1:-debug}"
PROJECT_DIR="/Users/flx/local/code/AutoHideAgent"
APP_BUNDLE="$PROJECT_DIR/build/AutoHideAgent.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DIST_DIR="$PROJECT_DIR/dist"

echo "==> Building AutoHideAgent (Swift 6, configuration: $MODE)..."
swift build --package-path "$PROJECT_DIR" -c "$MODE"

BIN_PATH=$(swift build --package-path "$PROJECT_DIR" -c "$MODE" --show-bin-path)
EXECUTABLE="$BIN_PATH/AutoHideAgent"

echo "==> Stopping any running AutoHideAgent instance..."
pkill -x AutoHideAgent || true
sleep 0.4

echo "==> Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/AutoHideAgent"
if [[ -f "$PROJECT_DIR/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
sed 's/\$(EXECUTABLE_NAME)/AutoHideAgent/g' "$PROJECT_DIR/Info.plist" > "$CONTENTS_DIR/Info.plist"
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

echo "==> Signing $APP_BUNDLE with ad-hoc signature and entitlements..."
codesign --force --deep --sign - --entitlements "$PROJECT_DIR/AutoHideAgent.entitlements" "$APP_BUNDLE"

if [[ "$MODE" == "release" ]]; then
    mkdir -p "$DIST_DIR"
    ZIP_PATH="$DIST_DIR/AutoHideAgent-macOS-v1.0.0.zip"
    rm -f "$ZIP_PATH"
    echo "==> Creating Release archive at $ZIP_PATH..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"
    echo "==> Release ZIP ready: $ZIP_PATH"
fi

echo "==> Bundle ready at: $APP_BUNDLE"
