# AI Agent & Contributor Guide (`AGENTS.md` / `CLAUDE.md`)

This document provides complete context for AI coding assistants (**Claude Code**, **OpenAI Codex / ChatGPT**, **Cursor**, **Antigravity**) working on `AutoHideAgent`.

---

## 1. Tech Stack & Compiler Constraints
- **Language:** Swift 6.0 (`swiftSettings: [.swiftLanguageMode(.v6)]` in `Package.swift`).
- **Minimum Deployment Target:** macOS 14.0 (`Sonoma` / `Sequoia`).
- **Concurrency Rules:**
  - `AutoHideManager`, `AppDelegate`, `MainDashboardView`, and `MenuPopoverView` are strictly `@MainActor`-isolated.
  - When registering `NotificationCenter` or `Timer` closures that execute on `.main`, always wrap mutations in `MainActor.assumeIsolated { ... }` and capture only `Sendable` values (such as `pid_t`, `Bool`, `String`) before entering the closure to avoid Swift 6 `Sendable` data-race errors.
  - For `AXIsProcessTrustedWithOptions`, use `"AXTrustedCheckOptionPrompt" as CFString` rather than the non-const C global `kAXTrustedCheckOptionPrompt` to satisfy Swift 6 strict concurrency.

---

## 2. Key Files & Responsibilities

| File | Responsibility |
| :--- | :--- |
| `Sources/AutoHideAgent/App.swift` | `@main` `AppDelegate`, `NSWindow` (`MainDashboardView`), standard macOS `NSMenu` bar, `NSStatusItem` (left-click popover, right-click instant hide), and `.transient` `NSPopover`. |
| `Sources/AutoHideAgent/AutoHideManager.swift` | Core `@MainActor @Observable` state machine. Handles `UserDefaults` persistence, `NSWorkspace` & `DistributedNotificationCenter` observers, sleep/dark-screen/screensaver/lock pause shifting, `CGEventSource` HID idle guard, `IOKit` `IOPMCopyAssertionsByProcess` media/call protection, `AXUIElement` hide fallback, and dual logging. |
| `Sources/AutoHideAgent/MainDashboardView.swift` | Full macOS desktop window (`NavigationSplitView`). Left sidebar holds settings cards; right detail pane hosts **Running Apps**, **Exclusions**, and **Recent Activity** tabs. |
| `Sources/AutoHideAgent/MenuPopoverView.swift` | Compact 330pt Control-Center-style menu bar popover with quick actions, segmented presets, `Exclusions` / `Live Timers` toggle, and **Recent Activity** log. |
| `Tests/AutoHideAgentTests/AutoHideAgentTests.swift` | Automated unit test suite using Swift's native `Testing` framework (`@Suite`, `@Test`, `#expect`). |
| `bundle.sh` | Compiles the binary, constructs `build/AutoHideAgent.app`, copies `Info.plist` and `AppIcon.icns`, and signs with `AutoHideAgent.entitlements`. |

---

## 3. Standard Development & Verification Workflow

Whenever you modify any Swift file in `Sources/` or `Tests/`:

1. **Run the Unit Test Suite:**
   ```bash
   swift test --package-path /Users/flx/local/code/AutoHideAgent
   ```
   Ensure all tests pass with **0 warnings** and **0 errors**.

2. **Rebuild & Re-bundle `AutoHideAgent.app`:**
   ```bash
   /Users/flx/local/code/AutoHideAgent/bundle.sh
   ```
   *(Note: `bundle.sh` automatically stops any running `AutoHideAgent` process before replacing the `.app` bundle so LaunchServices never throws `-609`.)*

3. **Launch & Verify:**
   ```bash
   open /Users/flx/local/code/AutoHideAgent/build/AutoHideAgent.app
   ```

---

## 4. Diagnostic Log Format (For Bug Triage)
- User-facing logs are stored in `manager.activityLogs` (`[ActivityLogEntry]`) and written to disk at:
  `~/Library/Logs/AutoHideAgent/AutoHideAgent.log`
- Whenever you add a new user-facing action or setting toggle in `AutoHideManager`, always call:
  ```swift
  appendLog(.info, "Human-friendly sentence for everyday users.", technical: "key=value diagnostic context")
  ```
  so both the UI's **Recent Activity** feed and the exported `.log` file stay synchronized.
