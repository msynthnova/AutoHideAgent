#!/bin/zsh
set -euo pipefail

# Usage:
#   ./publish.sh                          # Interactive prompt for bump type & description
#   ./publish.sh patch "Release notes"    # Bump 1.4.0 -> 1.4.1 (Build +1)
#   ./publish.sh minor "Release notes"    # Bump 1.4.0 -> 1.5.0 (Build +1)
#   ./publish.sh major "Release notes"    # Bump 1.4.0 -> 2.0.0 (Build +1)
#   ./publish.sh 1.4.1 "Release notes"    # Explicit version bump

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAP_DIR="/opt/homebrew/Library/Taps/msynthnova/homebrew-tap"

# Ensure SDKROOT points to a valid directory to prevent xcrun/swift failures
if [[ -n "${SDKROOT:-}" && ! -d "$SDKROOT" ]]; then
    unset SDKROOT
fi
if [[ -z "${SDKROOT:-}" ]]; then
    export SDKROOT="$(xcrun -sdk macosx --show-sdk-path 2>/dev/null || true)"
fi

# 1. Parse Current Version and Build Number
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Info.plist" 2>/dev/null || echo "1.4.0")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PROJECT_DIR/Info.plist" 2>/dev/null || echo "6")

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
MAJOR=${MAJOR:-1}
MINOR=${MINOR:-0}
PATCH=${PATCH:-0}

BUMP_TYPE="${1:-}"
RELEASE_DESC="${2:-}"

if [[ -z "$BUMP_TYPE" ]]; then
    echo "Current Version: $CURRENT_VERSION (Build $CURRENT_BUILD)"
    echo "Choose version bump type:"
    echo "  1) patch -> $MAJOR.$MINOR.$((PATCH + 1)) (Bug fixes, minor tweaks)"
    echo "  2) minor -> $MAJOR.$((MINOR + 1)).0 (New features, UI additions)"
    echo "  3) major -> $((MAJOR + 1)).0.0 (Breaking changes, major overhaul)"
    read -r "USER_CHOICE?Select [1-3] or type explicit version (e.g. 1.4.1): "
    case "$USER_CHOICE" in
        1|patch) BUMP_TYPE="patch" ;;
        2|minor) BUMP_TYPE="minor" ;;
        3|major) BUMP_TYPE="major" ;;
        *) BUMP_TYPE="$USER_CHOICE" ;;
    esac
fi

case "$BUMP_TYPE" in
    patch)
        NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
        ;;
    minor)
        NEW_VERSION="$MAJOR.$((MINOR + 1)).0"
        ;;
    major)
        NEW_VERSION="$((MAJOR + 1)).0.0"
        ;;
    *)
        if [[ "$BUMP_TYPE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            NEW_VERSION="$BUMP_TYPE"
        else
            echo "ERROR: Invalid version format '$BUMP_TYPE'. Expected 'patch', 'minor', 'major', or 'X.Y.Z'."
            exit 1
        fi
        ;;
esac

if [[ "${PUBLISH_PREPARED:-0}" == "1" ]]; then
    if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
        echo "ERROR: Prepared version must match Info.plist." >&2
        exit 1
    fi
    NEW_BUILD="$CURRENT_BUILD"
else
    NEW_BUILD=$((CURRENT_BUILD + 1))
fi

if [[ -z "$RELEASE_DESC" ]]; then
    read -r "RELEASE_DESC?Enter brief release description: "
fi
if [[ -z "$RELEASE_DESC" ]]; then
    RELEASE_DESC="Maintenance update and improvements"
fi

echo "=========================================================="
echo " Publishing AutoHideAgent v${NEW_VERSION} (Build ${NEW_BUILD})"
echo " Description: ${RELEASE_DESC}"
echo "=========================================================="

# Validate credentials and version before changing release files.
if [[ "${PREPARE_ONLY:-0}" != "1" ]]; then
    python3 "$PROJECT_DIR/scripts/github_release.py" preflight "$NEW_VERSION"
fi
if git -C "$PROJECT_DIR" rev-parse "v${NEW_VERSION}" >/dev/null 2>&1; then
    echo "ERROR: Release tag v${NEW_VERSION} already exists." >&2
    exit 1
fi

# 2. Run automated test suite first
echo "==> Step 1/6: Running test suite..."
env -u SDKROOT swift test --package-path "$PROJECT_DIR"

# 3. Bump version in files
echo "==> Step 2/6: Bumping version to $NEW_VERSION (Build $NEW_BUILD)..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PROJECT_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PROJECT_DIR/Info.plist"

perl -pi -e "s/(CFBundleShortVersionString\"\) as\? String \?\? \")[^\"]+\"/\${1}${NEW_VERSION}\"/g" "$PROJECT_DIR/Sources/AutoHideAgent/MainDashboardView.swift"
perl -pi -e "s/(CFBundleVersion\"\) as\? String \?\? \")[^\"]+\"/\${1}${NEW_BUILD}\"/g" "$PROJECT_DIR/Sources/AutoHideAgent/MainDashboardView.swift"
perl -pi -e "s/AutoHideAgent-macOS-v\d+\.\d+\.\d+/AutoHideAgent-macOS-v${NEW_VERSION}/g" "$PROJECT_DIR/README.md"

# 4. Run release build, codesign, Apple Notarization, stapling, and Sparkle packaging
echo "==> Step 3/6: Building, signing, notarizing, and packaging release..."
"$PROJECT_DIR/bundle.sh" release "$NEW_VERSION"

DIST_ZIP="$PROJECT_DIR/dist/AutoHideAgent-macOS-v${NEW_VERSION}.zip"
SHA256_FILE="$DIST_ZIP.sha256"

if [[ ! -f "$DIST_ZIP" || ! -f "$SHA256_FILE" ]]; then
    echo "ERROR: Release archive was not created at $DIST_ZIP!"
    exit 1
fi
SHA256_VAL=$(awk '{print $1}' "$SHA256_FILE")

if [[ "${PREPARE_ONLY:-0}" == "1" ]]; then
    echo "Prepared notarized v${NEW_VERSION} (Build ${NEW_BUILD}); not published."
    echo "Resume: PUBLISH_PREPARED=1 ./publish.sh $NEW_VERSION <release-description>"
    exit 0
fi

# 5. Commit the complete, tested implementation and tag locally.
echo "==> Step 4/6: Committing and tagging release in git..."
cd "$PROJECT_DIR"
git add Casks/ Info.plist README.md Sources/ Tests/ scripts/ appcast.xml bundle.sh publish.sh DEVELOPMENT.md .agentrules "$DIST_ZIP" "$SHA256_FILE"
if ! git diff --cached --quiet; then
    git commit -m "Release v${NEW_VERSION}: ${RELEASE_DESC}"
fi
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}: ${RELEASE_DESC}"

# Upload all assets to a draft first; fail on any API or upload error.
echo "==> Step 5/6: Uploading and publishing GitHub release..."
python3 "$PROJECT_DIR/scripts/github_release.py" upload "$NEW_VERSION" "$NEW_BUILD" "$RELEASE_DESC" "$SHA256_VAL"
python3 "$PROJECT_DIR/scripts/github_release.py" push "$NEW_VERSION" "$PROJECT_DIR" "v${NEW_VERSION}"
python3 "$PROJECT_DIR/scripts/github_release.py" publish "$NEW_VERSION"
# Expose the new Sparkle feed only once the downloads are live.
python3 "$PROJECT_DIR/scripts/github_release.py" push "$NEW_VERSION" "$PROJECT_DIR" main

# 6. Update the tap only after the release assets are public.
echo "==> Step 6/6: Updating Homebrew tap repository..."
if [[ -d "$TAP_DIR" ]]; then
    cp "$PROJECT_DIR/Casks/autohideagent.rb" "$TAP_DIR/Casks/autohideagent.rb"
    git -C "$TAP_DIR" add Casks/autohideagent.rb
    if ! git -C "$TAP_DIR" diff --cached --quiet; then
        git -C "$TAP_DIR" commit -m "Update autohideagent to v${NEW_VERSION} (Notarized)"
    fi
    python3 "$PROJECT_DIR/scripts/github_release.py" push "$NEW_VERSION" "$TAP_DIR" main
else
    echo "WARNING: Homebrew tap checkout not found; tap was not updated."
fi

echo "Release v${NEW_VERSION} published: https://github.com/msynthnova/AutoHideAgent/releases/tag/v${NEW_VERSION}"
echo "Release ZIP: $DIST_ZIP"
echo "SHA-256: $SHA256_VAL"
echo "/Applications/AutoHideAgent.app was not modified."
