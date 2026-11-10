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

NEW_BUILD=$((CURRENT_BUILD + 1))

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

# 2. Run automated test suite first
echo "==> Step 1/6: Running test suite..."
swift test --package-path "$PROJECT_DIR"

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

# 5. Git Commit and Tag in AutoHideAgent
echo "==> Step 4/6: Committing and tagging release in git..."
cd "$PROJECT_DIR"
git add Casks/autohideagent.rb Info.plist README.md Sources/AutoHideAgent/MainDashboardView.swift appcast.xml bundle.sh publish.sh dist/AutoHideAgent-macOS-v${NEW_VERSION}.zip dist/AutoHideAgent-macOS-v${NEW_VERSION}.zip.sha256
git commit -m "Release v${NEW_VERSION}: ${RELEASE_DESC}"
git push origin main

git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}: ${RELEASE_DESC}"
git push origin "v${NEW_VERSION}"

# 6. Publish GitHub Release via API
echo "==> Step 5/6: Publishing GitHub release and uploading assets..."
GH_TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential-osxkeychain get 2>/dev/null | sed -n 's/^password=//p' || true)
if [[ -z "$GH_TOKEN" && -n "${GITHUB_TOKEN:-}" ]]; then
    GH_TOKEN="$GITHUB_TOKEN"
fi

if [[ -n "$GH_TOKEN" ]]; then
    RELEASE_RESPONSE=$(curl -s -X POST -H "Authorization: token $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/msynthnova/AutoHideAgent/releases \
      -d "{
        \"tag_name\": \"v${NEW_VERSION}\",
        \"name\": \"AutoHideAgent v${NEW_VERSION} (Notarized)\",
        \"body\": \"## AutoHideAgent v${NEW_VERSION}\\\\n\\\\n- ${RELEASE_DESC}\\\\n\\\\n### Verification\\\\n- **Signed:** Apple Developer ID Application\\\\n- **Notarized:** Apple Notary Service (Ticket stapled)\\\\n- **SHA-256:** \`${SHA256_VAL}\`\"
      }")

    RELEASE_ID=$(echo "$RELEASE_RESPONSE" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | head -n 1)

    if [[ -n "$RELEASE_ID" && "$RELEASE_ID" != "0" ]]; then
        echo "    Uploading Release ZIP to GitHub..."
        curl -s -X POST -H "Authorization: token $GH_TOKEN" \
          -H "Content-Type: application/zip" \
          --data-binary @"$DIST_ZIP" \
          "https://uploads.github.com/repos/msynthnova/AutoHideAgent/releases/$RELEASE_ID/assets?name=AutoHideAgent-macOS-v${NEW_VERSION}.zip" >/dev/null

        echo "    Uploading SHA256 checksum to GitHub..."
        curl -s -X POST -H "Authorization: token $GH_TOKEN" \
          -H "Content-Type: text/plain" \
          --data-binary @"$SHA256_FILE" \
          "https://uploads.github.com/repos/msynthnova/AutoHideAgent/releases/$RELEASE_ID/assets?name=AutoHideAgent-macOS-v${NEW_VERSION}.zip.sha256" >/dev/null
        echo "    GitHub Release published: https://github.com/msynthnova/AutoHideAgent/releases/tag/v${NEW_VERSION}"
    else
        echo "WARNING: Could not create GitHub release via API. Response: $RELEASE_RESPONSE"
    fi
else
    echo "WARNING: GitHub token not found in keychain. Skipped automatic GitHub release creation."
fi

# 7. Update Homebrew Tap
echo "==> Step 6/6: Updating Homebrew tap repository..."
if [[ -d "$TAP_DIR" ]]; then
    cd "$TAP_DIR"
    git add Casks/autohideagent.rb
    git commit -m "Update autohideagent to v${NEW_VERSION} (Notarized)" || true
    git push origin main || true
    echo "    Homebrew tap synced to main."
else
    echo "WARNING: Homebrew tap directory $TAP_DIR not found."
fi

cd "$PROJECT_DIR"
echo ""
echo "=========================================================="
echo " Release v${NEW_VERSION} successfully published!"
echo " Release ZIP:  $DIST_ZIP"
echo " SHA-256:      $SHA256_VAL"
echo " GitHub Tag:   https://github.com/msynthnova/AutoHideAgent/releases/tag/v${NEW_VERSION}"
echo " Homebrew Tap: https://github.com/msynthnova/homebrew-tap"
echo ""
echo " NOTE: /Applications/AutoHideAgent.app was NOT modified."
echo " To install/upgrade the release yourself as an end user:"
echo "   brew update && brew upgrade --cask --greedy autohideagent"
echo "=========================================================="
