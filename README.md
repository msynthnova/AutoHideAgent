# AutoHideAgent (`AutoHideAgent`) for macOS

**AutoHideAgent** is a native macOS desktop and menu bar application written in **Swift 6** that automatically hides or gracefully quits inactive background applications after a configurable threshold—keeping your workspace focused and clutter-free while intelligently pausing timers during sleep, screen-off, lock screen, screensaver, and active audio/video playback.

---

## Installation & Updates

AutoHideAgent supports two native update distribution channels: **Homebrew Cask** (CLI) and **Sparkle 2** (in-app updates).

### Method A: Homebrew Cask (Recommended for CLI & Developers)

Install directly via the custom tap:
```bash
# Add the tap and install AutoHideAgent (bypass Gatekeeper quarantine automatically)
brew install --cask --no-quarantine msynthnova/tap/autohideagent

# Update anytime via Homebrew:
brew upgrade --cask autohideagent
```

### Method B: In-App Updates via Sparkle 2

- AutoHideAgent embeds **Sparkle 2** with EdDSA (ed25519) cryptographic signature verification.
- **Automatic Checks:** Toggle "Automatically Check for Updates" in **General Settings**. AutoHideAgent checks for new versions once daily.
- **Manual Check:** Click **"Check for Updates…"** in:
  1. The macOS Application Menu (`AutoHideAgent` → `Check for Updates…`)
  2. The Control Center menu bar popover footer
  3. The **General Settings** tab in the main desktop window
- Feed URL: `https://raw.githubusercontent.com/msynthnova/AutoHideAgent/main/appcast.xml`

### Method C: Manual ZIP Download

- **Release Archive:** [`dist/AutoHideAgent-macOS-v1.0.0.zip`](./dist/AutoHideAgent-macOS-v1.0.0.zip)
- **SHA-256 Checksum:** [`dist/AutoHideAgent-macOS-v1.0.0.zip.sha256`](./dist/AutoHideAgent-macOS-v1.0.0.zip.sha256)
- **Appcast Feed:** [`appcast.xml`](./appcast.xml)

1. Extract `dist/AutoHideAgent-macOS-v1.0.0.zip`.
2. Move `AutoHideAgent.app` to `/Applications`.
3. If macOS blocks opening on first launch ("Apple could not verify AutoHideAgent is free of malware"):
   - Click **Done**, open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**.
   - Or run in Terminal: `xattr -cr /Applications/AutoHideAgent.app`
4. Grant Accessibility permissions when prompted on first run.

---

## Key Features

### 1. Desktop-First App + Optional Menu Bar & Dock Modes
- **System Settings-Style Desktop Dashboard (`MainDashboardView.swift`):** Clean, proportional macOS interface (`maxWidth: 680` detail canvas so it never stretches awkwardly on large 27"–32" monitors) with four sidebar sections:
  - **Dashboard:** Configure Auto-Hide, Auto-Quit, Smart Protections, and App Presence.
  - **Running Apps:** Live-ticking inactivity countdowns for every open `.regular` app with one-click **Exclude**, **Hide**, and **Quit** buttons.
  - **Exclusions:** Whitelist manager (pick from currently running apps or enter a Bundle ID / App Name manually).
  - **Activity Log:** Plain-English event history with technical diagnostic subtitles and one-click **Open Log File** / **Reveal in Finder** buttons.
- **Dynamic Presence Controls (`showInDock` & `showInMenuBar`):**
  - Run as a full Dock + Menu Bar app, Dock-only app, or Menu Bar-only utility (`NSApplication.ActivationPolicy.regular` ↔ `.accessory`) on the fly without restarting.
  - Built-in safety guard prevents disabling both Dock and Menu Bar simultaneously.
- **Fast Menu Bar Popover (`MenuPopoverView.swift`):**
  - **Left-click** the menu bar icon to open a compact `320pt` control center with live app rows, quick toggles, and an **Open Full App** button.
  - **Right-click** (or Control-click) the menu bar icon to **immediately hide all visible background apps** in 1 click.

### 2. Independent Auto-Hide (5m–1h) & Auto-Quit (1h–1d)
- **Auto-Hide Inactive Apps (`isAutoHideEnabled`):**
  - Presets: `5m`, `10m`, `15m`, `30m`, `1h`.
  - Attempts cooperative `NSRunningApplication.hide()` first, and automatically falls back to `AXUIElementSetAttributeValue(..., kAXHiddenAttribute, kCFBooleanTrue)` when macOS blocks cross-process hide from background agents.
- **Auto-Quit Inactive Apps (`isAutoQuitEnabled`):**
  - Presets: `1h`, `2h`, `6h`, `12h`, `1d`.
  - Uses graceful `NSRunningApplication.terminate()` (never `forceTerminate()`), so apps with unsaved changes can prompt to save.
  - Optional **"Ask for confirmation before quitting an app"** dialog (`confirmBeforeAutoQuit`) with 3 actions: **Quit [App]**, **Keep Open** (resets timer), or **Always Exclude [App]**.

### 3. Smart Protections & Hardware/Session Pause Engine
- **Global HID Idle Guard (`CGEventSource`):** Queries `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`. If you step away from your keyboard/mouse/trackpad, AutoHideAgent pauses evaluation—apps only hide or quit while you are actively working in another foreground app.
- **Sleep, Lid-Close, Screen-Off, Lock Screen & Screensaver Pause:**
  - Observes `NSWorkspace.willSleepNotification`, `didWakeNotification`, `screensDidSleepNotification`, `screensDidWakeNotification`, `CGDisplayIsAsleep(CGMainDisplayID())`, and `DistributedNotificationCenter` events (`com.apple.screensaver.didstart`/`didstop`, `com.apple.screenIsLocked`/`screenIsUnlocked`).
  - Tracks both wall-clock timestamps (`lastDeactivatedDates`) and XNU kernel monotonic awake time (`ProcessInfo.processInfo.systemUptime`). When your Mac wakes or unlocks, all timers shift forward by the exact paused duration.
- **Active Audio, Video & Call Protection (`IOKit`):**
  - Queries `IOPMCopyAssertionsByProcess` for active power/audio assertions (`PreventUserIdleDisplaySleep`, `PreventUserIdleSystemSleep`, `audio-out`, `audio-in`). Automatically protects apps like Spotify, Apple Music, Zoom, FaceTime, and VLC while playing media or on a call.
- **Keep Most Recent Background App Visible (`keepPreviousAppVisible`):**
  - Optional toggle that keeps the single most recently used background app visible behind your active window for side-by-side reference work.
- **1-Hour Snooze (`togglePauseForOneHour()`):**
  - One-click **Pause 1h** button for presentations or screen sharing that automatically resumes after 60 minutes.

### 4. Dual-Layer Logging & One-Click Bug Triage
- Every setting change, manual action, automatic hide/quit, and sleep/wake transition is logged in:
  1. **In-App Activity Log:** Written in friendly, everyday English.
  2. **Persistent Diagnostic File (`~/Library/Logs/AutoHideAgent/AutoHideAgent.log`):** Includes ISO-8601 timestamps, PIDs, Bundle IDs, `AXError` codes, and live `[SNAPSHOT]` dumps.

---

## Project Structure

```text
AutoHideAgent/
├── Package.swift                             # Swift 6 Package manifest (Sparkle 2 + test target)
├── Info.plist                                # macOS App bundle metadata (Sparkle SUFeedURL + EdDSA key)
├── AutoHideAgent.entitlements                # Unsandboxed entitlement definition
├── AppIcon.icns                              # Vector-rendered macOS squircle iconset
├── appcast.xml                               # Sparkle 2 RSS update feed with EdDSA signatures
├── Casks/
│   └── autohideagent.rb                      # Homebrew Cask formula
├── bundle.sh                                 # Build, package, Sparkle sign & Homebrew sync script
├── dist/
│   ├── AutoHideAgent-macOS-v1.0.0.zip        # Signed Release .app archive
│   └── AutoHideAgent-macOS-v1.0.0.zip.sha256 # SHA-256 checksum
├── README.md                                 # Comprehensive documentation
├── Sources/
│   └── AutoHideAgent/
│       ├── App.swift                         # @main AppDelegate, NSWindow, NSMenu, NSStatusItem & NSPopover
│       ├── AutoHideManager.swift             # Core @MainActor @Observable engine, timers, HID/IOKit/AX bridges
│       ├── UpdateController.swift            # Sparkle 2 standard updater controller & SwiftUI bindings
│       ├── MainDashboardView.swift           # Proportional macOS desktop window (NavigationSplitView)
│       └── MenuPopoverView.swift             # 308pt Control Center menu bar popover
└── Tests/
    └── AutoHideAgentTests/
        └── AutoHideAgentTests.swift          # Swift Testing (@Test) suite (9 unit tests)
```

---

## Building, Testing & Packaging from Source

### Prerequisites
- macOS 26.0 / 27.0+ with Xcode / Swift 6 toolchain installed.

### Commands
```bash
# 1. Run the automated Swift Testing unit test suite
swift test

# 2. Build a Release .app bundle and generate dist/AutoHideAgent-macOS-v1.0.0.zip
./bundle.sh release

# 3. Build a Debug .app bundle and launch it
./bundle.sh debug && open ./build/AutoHideAgent.app
```
