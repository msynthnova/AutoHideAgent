# macOS Liquid Glass App Blueprint & AI Agent Preferences

> **How to use this file:** Drop or paste this `.md` file at the start of any chat with Claude, ChatGPT / Codex, Cursor, or Antigravity when building a new macOS app. It defines my exact architectural, UI/UX (macOS 26/27+ Liquid Glass), menu bar, logging, self-cleanup, testing, and GitHub release standards.

---

## 1. Platform, Toolchain & Project Structure

- **Target OS & Language:** macOS 26.0 / 27.0+ (`arm64`), Swift 6.0+ with strict concurrency (`@MainActor`, `@Observable`).
- **Build System:** Swift Package Manager (`Package.swift`) + a self-contained `bundle.sh` script that compiles in **Release** mode (`swift build -c release`), generates `AppIcon.icns`, assembles `<AppName>.app`, signs with entitlements (`codesign --force --deep --sign -`), and packages distribution artifacts in `dist/`.
- **No Xcode Project Lock-in:** Must build, test (`swift test`), and package cleanly from the terminal using standard Command Line Tools / Xcode toolchain.

---

## 2. Desktop-First + Menu Bar Hybrid Architecture

1. **Desktop App First (`LSUIElement = false`):**
   - Always build a **normal macOS desktop application first** with a full main window (`NSWindow`), Dock icon, and standard macOS menu bar (`About`, `Settings ⌘,`, `Close Window ⌘W`, `Quit ⌘Q`).
   - Do **not** build a menu-bar-only app unless explicitly requested.
2. **Dynamic App Presence Toggles (Dock & Menu Bar):**
   - Provide user toggles in Settings to:
     - **Show in Dock** (`NSApp.setActivationPolicy(.regular)` vs `.accessory`)
     - **Show in Menu Bar** (`NSStatusItem` enabled/disabled)
   - **Safety Guard:** Never allow both toggles to be turned off simultaneously (if one is turned off, automatically keep or turn on the other so the user is never locked out of the UI).
3. **Single-Instance & Clean Re- bundling:**
   - Ensure `bundle.sh` gracefully stops any running instance (`killall <AppName> || true && sleep 0.4`) before replacing `<AppName>.app` and relaunching, avoiding LaunchServices `-609` errors.

---

## 3. macOS 26/27+ "Liquid Glass" UI & UX Standards

### A. High-Contrast Readability (Never Washed Out)
- **DO NOT** make the entire `NSWindow` transparent (`window.backgroundColor = .clear`) or stack translucent `.glassEffect()` layers behind body text. That causes severe contrast/readability issues over desktop wallpapers.
- **DO** use a solid native window canvas (`NSColor.windowBackgroundColor`) paired with high-contrast card surfaces (`Color(nsColor: .controlBackgroundColor)`) and a subtle `1pt` border (`Color.primary.opacity(0.09)`).
- **DO** use native macOS 26/27 **Liquid Glass** APIs (`SwiftUI.Glass`, `GlassEffectContainer`) on interactive controls, pills, toolbars, and action buttons:
  - `.buttonStyle(.glass)` for secondary actions
  - `.buttonStyle(.glassProminent)` for primary CTA buttons
- **Typography Hierarchy:**
  - Primary titles & labels: `.primary` (`.semibold` / `.medium`)
  - Supporting descriptions: `.secondary` (never faint `.tertiary` for essential info)
  - Live timers & numeric counters: `.monospacedDigit()`

### B. Anti-Stretch Responsive Layout for Large Monitors
- **Never let cards or toggles stretch edge-to-edge across a 27" or ultra-wide monitor.**
- Use a System-Settings-style `NavigationSplitView`:
  - **Sidebar:** Fixed width (`195pt–210pt`) with section navigation and a compact status badge at the bottom.
  - **Detail Canvas:** Wrap all detail content inside a `ScrollView` constrained to **`.frame(maxWidth: 680)`** and centered horizontally inside the detail pane (`frame(maxWidth: .infinity)`).
- **Default Window Geometry:** Compact and balanced by default (`760 × 540`, `minSize: 680 × 460`).

### C. Bug-Free Menu Bar Popover (`NSStatusItem` + `NSPopover`)
- Use `NSPopover` with `.transient` behavior and a custom `NSHostingController`.
- Always set `hostingController.sizingOptions = [.preferredContentSize]` and constrain the SwiftUI popover view to `.frame(width: 320)` so `NSPopover` automatically resizes to fit its content without clipping or jumping.
- When opening the popover on status item click:
  1. Call `NSApp.activate(ignoringOtherApps: true)`
  2. Call `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`
  3. Call `popover.contentViewController?.view.window?.makeKey()`
  4. Attach a global `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` monitor to dismiss the popover cleanly when clicking outside, and remove the monitor in `popoverDidClose`.
- Support **Left-Click** to toggle the popover and **Right-Click** for a quick primary action.

---

## 4. Smart Background Engine & Power/Display Awareness

- **Event-Driven First:** Prefer `NSWorkspace.shared.notificationCenter` and `DistributedNotificationCenter` events over heavy polling.
- **Monotonic Time Tracking:** Use `ProcessInfo.processInfo.systemUptime` alongside `Date()` to detect clock jumps or system sleep gaps.
- **Dark-Screen, Sleep, Screensaver & Lock Pause:**
  - Any background countdown or automation timer **must automatically pause** (and shift timestamps forward upon resume so no app/task is penalized for sleep time) during:
    1. System Sleep (`NSWorkspace.willSleepNotification` / `didWakeNotification`)
    2. Display Off / Dark Screen (`NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification` + `CGDisplayIsAsleep(CGMainDisplayID())`)
    3. Screensaver Active (`com.apple.screensaver.didstart` / `com.apple.screensaver.didstop`)
    4. Screen Locked (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`)
- **Confirmation Safety:** For destructive or disruptive actions (e.g., auto-quitting apps), include an optional user toggle to **Confirm Before Action** (`NSAlert` with Confirm / Skip / Disable options) plus a **1-Hour Snooze / Pause** button.

---

## 5. Self-Contained Storage & 1-Click Clean Uninstall

- **Self-Contained `.app`:** Keep all binaries and resources inside `<AppName>.app`. Never install root daemons or scatter files across the system.
- **Easy Uninstall / Self-Cleanup:**
  - Deleting `<AppName>.app` from `/Applications` should immediately stop the app with no background ghosts.
  - Always include a **"Reset & Clean Up App Data"** button in Settings that:
    1. Unregisters Launch at Login (`SMAppService.mainApp.unregister()`).
    2. Deletes `~/Library/Logs/<AppName>/`.
    3. Removes `UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)`.
    4. Offers to quit and reveal `<AppName>.app` in Finder so the user can drag it to the Trash with **zero** leftover files.

---

## 6. Dual Logging System (User Feed + Technical Log File)

Every app must include two synchronized logging layers:
1. **In-App Activity Feed (Plain English):**
   - Easy-to-read chronological feed in the UI with category icons, filter chips, search, **Copy Diagnostics**, and **Clear**.
2. **Persistent Technical Log File (`~/Library/Logs/<AppName>/<AppName>.log`):**
   - ISO-8601 timestamped entries with PID, bundle ID, return codes, permissions state, and error details.
   - Include two buttons in the UI: **Open Log File** and **Reveal in Finder**.

---

## 7. Documentation, Testing & GitHub CLI (`gh`) Release Workflow

1. **Multi-Agent Documentation:**
   - Always create and maintain:
     - `README.md` (features, architecture, build/test commands, permissions, troubleshooting)
     - `AGENTS.md` & `CLAUDE.md` (hand-off architecture guide, file map, invariants, and verification checklist for Claude Code, OpenAI Codex, and other AI agents)
2. **Automated Verification:**
   - Write unit tests in `Tests/<AppName>Tests/` and verify all tests pass via `swift test` before packaging.
3. **Release Packaging & Private GitHub Repo (`gh`):**
   - Package the Release build into `dist/<AppName>-macOS-v<Version>.zip` (and/or `.dmg`) + `.sha256` checksum.
   - Use GitHub CLI (`gh`) to create/update a **Private** repository (`gh repo create --private` or `gh repo edit --visibility private`), push commits and tags, and publish a GitHub Release (`gh release create`) with the packaged archive attached.
