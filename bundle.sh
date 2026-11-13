#!/bin/zsh
set -euo pipefail

# Usage:
#   ./bundle.sh            # Debug build & bundle
#   ./bundle.sh release    # Optimized Release build, Developer ID sign with Hardened Runtime,
#                          # Apple Notarization & Stapling, Sparkle sign & appcast, and Homebrew cask update

MODE="${1:-debug}"
if [[ "$MODE" != "debug" && "$MODE" != "release" ]]; then
    echo "ERROR: Expected debug or release configuration." >&2
    exit 1
fi
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure SDKROOT points to a valid directory to prevent xcrun/swift failures
if [[ -n "${SDKROOT:-}" && ! -d "$SDKROOT" ]]; then
    unset SDKROOT
fi
if [[ -z "${SDKROOT:-}" ]]; then
    export SDKROOT="$(xcrun -sdk macosx --show-sdk-path 2>/dev/null || true)"
fi

if [[ "$MODE" == "debug" ]]; then
    BUNDLE_NAME="AutoHideAgent Dev.app"
    BUNDLE_ID="com.systems.autohideagent.dev"
    DISPLAY_NAME="AutoHideAgent Dev"
else
    BUNDLE_NAME="AutoHideAgent.app"
    BUNDLE_ID="com.systems.autohideagent"
    DISPLAY_NAME="AutoHideAgent"
fi

APP_BUNDLE="$PROJECT_DIR/build/$BUNDLE_NAME"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
DIST_DIR="$PROJECT_DIR/dist"
APP_VERSION="${2:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Info.plist" 2>/dev/null || echo "1.4.0")}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"

echo "==> Building AutoHideAgent (Swift 6, configuration: $MODE, version: $APP_VERSION)..."
swift build --package-path "$PROJECT_DIR" -c "$MODE"

BIN_PATH=$(swift build --package-path "$PROJECT_DIR" -c "$MODE" --show-bin-path)
EXECUTABLE="$BIN_PATH/AutoHideAgent"

echo "==> Stopping any local build instance of AutoHideAgent ($APP_BUNDLE)..."
pkill -f "$APP_BUNDLE/Contents/MacOS/AutoHideAgent" 2>/dev/null || true
pkill -f "$PROJECT_DIR/build/AutoHideAgent.app/Contents/MacOS/AutoHideAgent" 2>/dev/null || true
sleep 0.3

echo "==> Packaging $APP_BUNDLE..."
if [[ -L "$APP_BUNDLE" ]]; then
    rm "$APP_BUNDLE"
else
    rm -rf "$APP_BUNDLE"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/AutoHideAgent"
if [[ "$MODE" == "release" ]]; then
    echo "==> Stripping local debug symbols & paths from binary..."
    strip -x "$MACOS_DIR/AutoHideAgent"
fi
if [[ -f "$PROJECT_DIR/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
sed 's/\$(EXECUTABLE_NAME)/AutoHideAgent/g' "$PROJECT_DIR/Info.plist" > "$CONTENTS_DIR/Info.plist"
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

if [[ "$MODE" == "debug" ]]; then
    echo "==> Configuring Dev bundle identity ($BUNDLE_ID)..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true

fi

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
    echo "ERROR: Sparkle.framework not found in .build directory!" >&2
    exit 1
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
    echo "==> Signing $APP_BUNDLE with specified identity '$SIGN_IDENTITY'..."
elif [[ "$MODE" == "release" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | awk '{print $2}' | head -n 1)
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "ERROR: Release requires a Developer ID Application certificate." >&2
        exit 1
    else
        echo "==> Signing Release $APP_BUNDLE with Developer ID SHA1: '$SIGN_IDENTITY'..."
    fi
else
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | awk '{print $2}' | head -n 1)
    if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="-"
        echo "==> Signing Debug $APP_BUNDLE with ad-hoc signature..."
    else
        echo "==> Signing Debug $APP_BUNDLE with Apple Development SHA1: '$SIGN_IDENTITY'..."
    fi
fi

# Codesign options
CODESIGN_FLAGS=(--force)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    CODESIGN_FLAGS+=(--timestamp --options runtime)
fi

# Sign Sparkle inner components first, then framework, then outer app
if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
    echo "==> Signing Sparkle framework internal components..."
    for xpc in "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/"*.xpc; do
        if [[ -d "$xpc" ]]; then
            codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$xpc"
        fi
    done
    if [[ -f "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Autoupdate" ]]; then
        codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Autoupdate"
    fi
    if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app" ]]; then
        codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app"
    fi
    codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
fi

echo "==> Signing main executable and app bundle..."
codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$MACOS_DIR/AutoHideAgent"
codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/AutoHideAgent.entitlements" "$APP_BUNDLE"

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ "$MODE" == "release" ]]; then
    mkdir -p "$DIST_DIR"

    # Apple Notarization
    if security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | grep -q "Developer ID Application"; then
        echo "==> Checking Apple Notary Service credentials for profile '$NOTARY_PROFILE'..."
        if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
            TEMP_NOTARY_ZIP="$DIST_DIR/AutoHideAgent-notarize.zip"
            rm -f "$TEMP_NOTARY_ZIP"
            echo "==> Packaging temporary archive for notarization submission..."
            ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$TEMP_NOTARY_ZIP"

            echo "==> Submitting to Apple Notary Service (waiting for response)..."
            SUBMIT_OUTPUT=$(xcrun notarytool submit "$TEMP_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait)
            echo "$SUBMIT_OUTPUT"
            rm -f "$TEMP_NOTARY_ZIP"

            SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | awk '/id:/ {print $2; exit}')
            if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
                echo "==> Apple Notarization SUCCESSFUL!"
                echo "==> Stapling notarization ticket to $APP_BUNDLE..."
                xcrun stapler staple "$APP_BUNDLE"
                echo "==> Validating Gatekeeper assessment..."
                spctl --assess --type execute --verbose "$APP_BUNDLE"
            else
                echo "==> ERROR: Apple Notarization was NOT accepted."
                if [[ -n "$SUBMISSION_ID" ]]; then
                    echo "==> Fetching notary log for submission $SUBMISSION_ID..."
                    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
                fi
                exit 1
            fi
        else
            echo "ERROR: Notary profile unavailable: $NOTARY_PROFILE" >&2
            exit 1
        fi
    else
        echo "ERROR: Release requires Developer ID signing and notarization." >&2
        exit 1
    fi

    ZIP_PATH="$DIST_DIR/AutoHideAgent-macOS-v${APP_VERSION}.zip"
    rm -f "$ZIP_PATH"
    echo "==> Creating final Release archive at $ZIP_PATH..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    
    SHA256_VAL=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
    echo "$SHA256_VAL  AutoHideAgent-macOS-v${APP_VERSION}.zip" > "$ZIP_PATH.sha256"
    echo "==> Release ZIP SHA256: $SHA256_VAL"

    # Sparkle sign & generate appcast.xml
    SPARKLE_BIN="$PROJECT_DIR/tools/sparkle/bin"
    if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
        echo "==> Fetching Sparkle CLI release tools on demand..."
        mkdir -p "$PROJECT_DIR/tools/sparkle"
        curl --fail --location --silent --show-error https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz | tar -xJf - -C "$PROJECT_DIR/tools/sparkle" ./bin
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
                --maximum-versions 0 \
                --download-url-prefix "https://github.com/msynthnova/AutoHideAgent/releases/download/v${APP_VERSION}/" \
                --ed-key-file "$PROJECT_DIR/.sparkle_priv.key" \
                "$DIST_DIR"
        else
            "$SPARKLE_BIN/generate_appcast" \
                --maximum-versions 0 \
                --download-url-prefix "https://github.com/msynthnova/AutoHideAgent/releases/download/v${APP_VERSION}/" \
                --account AutoHideAgent \
                "$DIST_DIR"
        fi

        python3 "$PROJECT_DIR/scripts/fix_appcast.py" "$DIST_DIR/appcast.xml"

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
  depends_on macos: :sequoia

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

echo "==> Release packaging complete. Bundle ready at: $APP_BUNDLE"
