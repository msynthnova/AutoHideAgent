# AutoHideAgent Development & Release Workflow

This document defines the development, commit, and release protocol for AutoHideAgent.

---

## 1. The Core Decision Rule (Always Ask First)

Whenever a feature, bug fix, or code change is completed, the developer/AI assistant must **stop and ask**:

> **"Should this change be a Commit only (save progress to git), or are we publishing a New Version Release?"**

Never proceed directly to a release without user confirmation.

---

## 2. Mode 1: Commit Only (Default / In-Progress Dev)

Use this when iterating, refactoring, fixing bugs in progress, or checkpointing work.

### Steps:
1. Run automated unit tests:
   ```bash
   swift test
   ```
2. Verify git status:
   ```bash
   git status
   ```
3. Commit and push:
   ```bash
   git add <modified files>
   git commit -m "feat/fix: clear description of change"
   git push origin main
   ```

### Constraints in Commit Mode:
- ❌ **Do NOT bump version** in `Info.plist`.
- ❌ **Do NOT submit** to Apple Notary Service.
- ❌ **Do NOT push git tags** or create GitHub releases.
- ❌ **Do NOT touch** the Homebrew tap.
- ❌ **Do NOT copy** to `/Applications/AutoHideAgent.app`.

---

## 3. Mode 2: New Version Release (Public Distribution)

Use this when changes are tested, polished, and ready for public download and Homebrew update.

### Automated 1-Command Release:
```bash
# Automated Patch Bump (e.g. 1.4.0 -> 1.4.1):
./publish.sh patch "Fix menu bar timer desync and improve responsive layout"

# Automated Minor Bump (e.g. 1.4.0 -> 1.5.0):
./publish.sh minor "Add per-app custom snooze thresholds"

# Explicit Version:
./publish.sh 1.4.1 "Release title"
```

### What `./publish.sh` Automates:
1. **Tests:** Runs the 9 Swift Testing unit tests (`swift test`). Aborts immediately if tests fail.
2. **Version Bump:** Increments `CFBundleShortVersionString` and `CFBundleVersion` across `Info.plist`, `MainDashboardView.swift`, and `README.md`.
3. **Optimized Build:** Compiles release binary with Swift 6 and strips debug symbols.
4. **Hardened Runtime Signing:**
   - Detects `Developer ID Application: Cong Nguyen (CWLFN66P3Q)`.
   - Signs all inner Sparkle 2 XPC services (`Downloader.xpc`, `Installer.xpc`, `Autoupdate`, `Updater.app`) with `--options runtime --timestamp`.
   - Signs outer `.app` bundle with `AutoHideAgent.entitlements`.
5. **Apple Notary Service Submission:**
   - Submits archive to Apple via Keychain profile `notarytool-profile`.
   - Waits for `status: Accepted`.
   - Staples the ticket using `xcrun stapler staple`.
   - Validates Gatekeeper assessment (`spctl --assess --type execute -vv`).
6. **Sparkle 2 EdDSA Signing & Appcast:**
   - Generates EdDSA signature using `.sparkle_priv.key`.
   - Updates `appcast.xml` at repository root.
7. **Homebrew Tap Sync:**
   - Updates `Casks/autohideagent.rb` with the new version and notarized ZIP SHA-256.
   - Syncs to `/opt/homebrew/Library/Taps/msynthnova/homebrew-tap/Casks/autohideagent.rb`.
   - Commits and pushes the tap to GitHub.
8. **GitHub Release:**
   - Commits and pushes `main` in `msynthnova/AutoHideAgent`.
   - Tags `vX.Y.Z` and pushes tag.
   - Creates GitHub Release via API and attaches the notarized ZIP + SHA-256 files.
9. **Zero-Touch Local Guarantee:**
   - **Never touches `/Applications/AutoHideAgent.app`**.
   - User installs and verifies the release themselves via Homebrew or ZIP download.

---

## 4. Local Testing vs. Production App Isolation

| Environment | Location | Launch Command | Purpose |
|---|---|---|---|
| **Local Dev Build** | `./build/AutoHideAgent.app` | `./bundle.sh debug && open ./build/AutoHideAgent.app` | Fast testing of uncommitted code; does not touch installed app |
| **Installed Production App** | `/Applications/AutoHideAgent.app` | Installed via Homebrew or GitHub Release | Daily driver app |

- Running `./bundle.sh debug` or `./bundle.sh release` writes only to `./build/` and `./dist/`.
- It will never overwrite `/Applications/AutoHideAgent.app`.
- To test the new release after publishing, test as an end user:
  ```bash
  brew update && brew upgrade --cask --greedy autohideagent
  ```

---

## 5. Security & Credentials Reference

- **Developer ID Identity:** `Developer ID Application: Cong Nguyen (CWLFN66P3Q)` (Stored in macOS login keychain)
- **Notary Profile:** `notarytool-profile` (Stored via `xcrun notarytool store-credentials`)
- **Sparkle Private Key:** `.sparkle_priv.key` (Ignored in `.gitignore`, stays local on development machine)
- **GitHub Token:** Stored in macOS Keychain under `protocol=https host=github.com` (accessed via `git credential-osxkeychain get`)

## November 2026 validation and release updates

- Tests: `unset SDKROOT && swift test` (16 tests). Test managers use isolated
  preferences, disabled monitoring, and forced dry-run mode.
- Development bundle: `build/AutoHideAgent Dev.app`; production release bundle:
  `build/AutoHideAgent.app`. Neither is a symlink to the other.
- Development bundles cannot install production Sparkle updates.
- Runtime minimum: macOS 15 (Sequoia), matching Package.swift and Info.plist.
- GitHub authentication: `gh auth login`, environment token, or macOS Keychain.
- Prepare without publishing: `PREPARE_ONLY=1 ./publish.sh patch "Description"`.
- Publish a prepared version without increasing its build again:
  `PUBLISH_PREPARED=1 ./publish.sh 1.4.7 "Description"`.
- Release signing, notarization, API calls, asset upload verification, and pushes
  fail the script on error. Draft assets are uploaded before publication; the
  Sparkle feed and Homebrew tap are pushed only after downloads are public.
- Unit tests, Developer ID signing, Apple notarization, Gatekeeper, Sparkle archive
  and delta signatures, and an isolated development launch smoke test were verified
  for v1.4.7, Build 14. Full live hide/quit behavior was not exercised on user apps.
