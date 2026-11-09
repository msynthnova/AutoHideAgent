#!/bin/zsh
set -euo pipefail

# Usage:
#   ./bundle.sh            # Debug build & bundle
#   ./bundle.sh release    # Optimized Release build, bundle, Sparkle sign & appcast, and Homebrew cask update

MODE="${1:-debug}"
PROJECT_DIR="/Users/flx/local/code/AutoHideAgent"
APP_BUNDLE="$PROJECT_DIR/build/AutoHideAgent.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
DIST_DIR="$PROJECT_DIR/dist"
APP_VERSION="1.0.0"

echo "==> Building AutoHideAgent (Swift 6, configuration: $MODE)..."
swift build --package-path "$PROJECT_DIR" -c "$MODE"

BIN_PATH=$(swift build --package-path "$PROJECT_DIR" -c "$MODE" --show-bin-path)
EXECUTABLE="$BIN_PATH/AutoHideAgent"

echo "==> Stopping any running AutoHideAgent instance..."
pkill -x AutoHideAgent || true
sleep 0.4

echo "==> Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/AutoHideAgent"
if [[ -f "$PROJECT_DIR/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
sed 's/\$(EXECUTABLE_NAME)/AutoHideAgent/g' "$PROJECT_DIR/Info.plist" > "$CONTENTS_DIR/Info.plist"
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Embed Sparkle.framework
SPARKLE_SOURCE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_SOURCE" ]]; then
    SPARKLE_SOURCE=$(find "$PROJECT_DIR/.build" -name "Sparkle.framework" -type d | head -n 1)
fi

if [[ -d "$SPARKLE_SOURCE" ]]; then
    echo "==> Embedding Sparkle.framework..."
    cp -R "$SPARKLE_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
    install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS_DIR/AutoHideAgent" 2>/dev/null || true
else
    echo "WARNING: Sparkle.framework not found in .build directory!"
fi

# Prefer real Apple Development identity from Keychain so Accessibility (TCC)
# permission persists across rebuilds instead of breaking on ad-hoc cdhash changes.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
    echo "==> Signing $APP_BUNDLE with ad-hoc signature..."
else
    echo "==> Signing $APP_BUNDLE with '$SIGN_IDENTITY'..."
fi

# Sign Sparkle inner components first, then framework, then outer app
if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/org.sparkle-project.InstallerConnection.xpc" 2>/dev/null || true
    codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/org.sparkle-project.InstallerStatus.xpc" 2>/dev/null || true
    codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
    codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/AutoHideAgent.entitlements" "$APP_BUNDLE"

if [[ "$MODE" == "release" ]]; then
    mkdir -p "$DIST_DIR"
    ZIP_PATH="$DIST_DIR/AutoHideAgent-macOS-v${APP_VERSION}.zip"
    rm -f "$ZIP_PATH"
    echo "==> Creating Release archive at $ZIP_PATH..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    
    SHA256_VAL=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
    echo "$SHA256_VAL  AutoHideAgent-macOS-v${APP_VERSION}.zip" > "$ZIP_PATH.sha256"
    echo "==> Release ZIP SHA256: $SHA256_VAL"

    # Sparkle sign & generate appcast.xml
    SPARKLE_BIN="$PROJECT_DIR/tools/sparkle/bin"
    if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
        echo "==> Fetching Sparkle CLI release tools on demand..."
        mkdir -p "$PROJECT_DIR/tools/sparkle"
        curl -L -s https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz | tar -xJf - -C "$PROJECT_DIR/tools/sparkle" ./bin
    fi

    if [[ -x "$SPARKLE_BIN/sign_update" ]]; then
        echo "==> Generating Sparkle EdDSA signature..."
        if [[ -f "$PROJECT_DIR/.sparkle_priv.key" ]]; then
            SIGN_SIG=$("$SPARKLE_BIN/sign_update" --ed-key-file "$PROJECT_DIR/.sparkle_priv.key" -p "$ZIP_PATH")
        else
            SIGN_SIG=$("$SPARKLE_BIN/sign_update" --account AutoHideAgent -p "$ZIP_PATH")
        fi
        echo "    EdDSA Signature: $SIGN_SIG"

        echo "==> Generating appcast.xml..."
        if [[ -f "$PROJECT_DIR/.sparkle_priv.key" ]]; then
            "$SPARKLE_BIN/generate_appcast" \
                --download-url-prefix "https://github.com/msynthnova/AutoHideAgent/releases/download/v${APP_VERSION}/" \
                --ed-key-file "$PROJECT_DIR/.sparkle_priv.key" \
                "$DIST_DIR"
        else
            "$SPARKLE_BIN/generate_appcast" \
                --download-url-prefix "https://github.com/msynthnova/AutoHideAgent/releases/download/v${APP_VERSION}/" \
                --account AutoHideAgent \
                "$DIST_DIR"
        fi

        # Sync appcast.xml to repo root for raw GitHub URL access and clean dist/
        if [[ -f "$DIST_DIR/appcast.xml" ]]; then
            cp "$DIST_DIR/appcast.xml" "$PROJECT_DIR/appcast.xml"
            rm -f "$DIST_DIR/appcast.xml"
            echo "==> appcast.xml updated at project root."
        fi
    fi

    # Update Homebrew Cask formula
    mkdir -p "$PROJECT_DIR/Casks"
    CASK_FILE="$PROJECT_DIR/Casks/autohideagent.rb"
    cat <<EOF > "$CASK_FILE"
cask "autohideagent" do
  version "${APP_VERSION}"
  sha256 "${SHA256_VAL}"

  url "https://github.com/msynthnova/AutoHideAgent/releases/download/v#{version}/AutoHideAgent-macOS-v#{version}.zip"
  name "AutoHideAgent"
  desc "Automatic background window cleaner and memory optimizer for macOS"
  homepage "https://github.com/msynthnova/AutoHideAgent"

  auto_updates true
  depends_on macos: :sonoma

  app "AutoHideAgent.app"

  zap trash: [
    "~/Library/Application Support/AutoHideAgent",
    "~/Library/Caches/com.systems.autohideagent",
    "~/Library/Logs/AutoHideAgent",
    "~/Library/Preferences/com.systems.autohideagent.plist",
  ]
end
EOF
    echo "==> Homebrew Cask formula updated at $CASK_FILE"
fi

echo "==> Bundle ready at: $APP_BUNDLE"
