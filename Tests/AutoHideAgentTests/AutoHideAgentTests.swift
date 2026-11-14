import Foundation
import Testing
@testable import AutoHideAgent

@Suite("AutoHideAgent Core Logic & State Suite")
@MainActor
final class AutoHideAgentTests {
    private let suiteName = "AutoHideAgentTests.\(UUID().uuidString)"
    private let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private lazy var defaults = UserDefaults(suiteName: suiteName)!

    private func makeManager() -> AutoHideManager {
        AutoHideManager(defaults: defaults, monitoringEnabled: false, dryRun: true, logDirectory: logDirectory)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }


    @Test("TimeoutPreset and QuitTimeoutPreset values and labels match specifications")
    func testTimeoutPresets() {
        // Auto-Hide presets: 5m to 1h
        #expect(TimeoutPreset.allCases.map(\.rawValue) == [300, 600, 900, 1800, 3600])
        #expect(TimeoutPreset.allCases.map(\.label) == ["5m", "10m", "15m", "30m", "1h"])

        // Auto-Quit presets: 1h to 1d
        #expect(QuitTimeoutPreset.allCases.map(\.rawValue) == [3600, 7200, 21600, 43200, 86400])
        #expect(QuitTimeoutPreset.allCases.map(\.label) == ["1h", "2h", "6h", "12h", "1d"])

        // Pause presets: 30m to 12h
        #expect(PausePreset.allCases.map(\.rawValue) == [1800, 3600, 7200, 14400, 28800, 43200])
        #expect(PausePreset.allCases.map(\.label) == ["30m", "1h", "2h", "4h", "8h", "12h"])
        #expect(PausePreset.allCases.map(\.descriptiveLabel) == ["30 Minutes", "1 Hour", "2 Hours", "4 Hours", "8 Hours", "12 Hours"])
    }

    @Test("Friendly duration formatting produces clear everyday strings")
    func testFriendlyDurationFormatter() {
        let manager = makeManager()
        #expect(manager.formatFriendlyDuration(45) == "45 sec")
        #expect(manager.formatFriendlyDuration(60) == "1 min")
        #expect(manager.formatFriendlyDuration(900) == "15 mins")
        #expect(manager.formatFriendlyDuration(3600) == "1 hr")
        #expect(manager.formatFriendlyDuration(7200) == "2 hrs")
        #expect(manager.formatFriendlyDuration(5400) == "1h 30m")
    }

    @Test("Whitelist management adds, deduplicates case-insensitively, removes, and logs events")
    func testWhitelistManagement() {
        let manager = makeManager()
        let testBundleID = "com.example.TestUnitApp"
        manager.removeWhitelistEntry(testBundleID)

        let initialCount = manager.whitelistedBundleIDs.count
        manager.addWhitelistEntry(testBundleID)
        #expect(manager.whitelistedBundleIDs.count == initialCount + 1)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Exclusions") == true)

        // Case-insensitive duplicate should be ignored
        manager.addWhitelistEntry("COM.EXAMPLE.TESTUNITAPP")
        #expect(manager.whitelistedBundleIDs.count == initialCount + 1)

        // Removal
        manager.removeWhitelistEntry(testBundleID)
        #expect(manager.whitelistedBundleIDs.count == initialCount)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Removed") == true)
    }

    @Test("Independent toggles for Auto-Hide, Auto-Quit, and Smart Protections log to Recent Activity")
    func testFeatureTogglesAndLogging() {
        let manager = makeManager()
        let originalHide = manager.isAutoHideEnabled
        let originalQuit = manager.isAutoQuitEnabled
        let originalConfirm = manager.confirmBeforeAutoQuit
        let originalKeepPrev = manager.keepPreviousAppVisible
        let originalProtectMedia = manager.protectActiveMediaApps

        defer {
            manager.isAutoHideEnabled = originalHide
            manager.isAutoQuitEnabled = originalQuit
            manager.confirmBeforeAutoQuit = originalConfirm
            manager.keepPreviousAppVisible = originalKeepPrev
            manager.protectActiveMediaApps = originalProtectMedia
        }

        manager.isAutoHideEnabled = !originalHide
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Auto-Hide") == true)

        manager.isAutoQuitEnabled = !originalQuit
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Auto-Quit") == true)

        manager.confirmBeforeAutoQuit = !originalConfirm
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("confirmation") == true)

        manager.keepPreviousAppVisible = !originalKeepPrev
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("recent") == true)

        manager.protectActiveMediaApps = !originalProtectMedia
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("protection") == true || manager.activityLogs.first?.userFriendlyMessage.contains("Protecting") == true)
    }

    @Test("Pause for 1 Hour snooze state activates and resumes cleanly")
    func testPauseForOneHourSnooze() {
        let manager = makeManager()
        #expect(manager.isTemporarilyPaused == false)

        manager.togglePauseForOneHour()
        #expect(manager.isTemporarilyPaused == true)
        #expect(manager.pausedUntilDate != nil)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("1 hour") == true || manager.activityLogs.first?.userFriendlyMessage.contains("1 hr") == true)

        manager.resumeFromTemporaryPause()
        #expect(manager.isTemporarilyPaused == false)
        #expect(manager.pausedUntilDate == nil)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Resumed AutoHide") == true)
    }

    @Test("PausePreset can pause for various durations from 30 minutes to 12 hours and resume")
    func testPausePresets() {
        let manager = makeManager()
        #expect(manager.isTemporarilyPaused == false)

        // 30 Minutes
        manager.pause(for: 1800)
        #expect(manager.isTemporarilyPaused == true)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("30 mins") == true)
        manager.resumeFromTemporaryPause()
        #expect(manager.isTemporarilyPaused == false)

        // 12 Hours
        manager.pause(for: 43200)
        #expect(manager.isTemporarilyPaused == true)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("12 hrs") == true)
        manager.resumeFromTemporaryPause()
        #expect(manager.isTemporarilyPaused == false)
    }

    @Test("Alert feature toggles for hide and quit persist and log cleanly")
    func testAlertFeatureToggles() {
        let manager = makeManager()
        let origHide = manager.alertOnAppHide
        let origQuit = manager.alertOnAppQuit
        defer {
            manager.alertOnAppHide = origHide
            manager.alertOnAppQuit = origQuit
        }

        manager.alertOnAppHide = !origHide
        #expect(manager.alertOnAppHide == !origHide)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("notifications") == true || manager.activityLogs.first?.userFriendlyMessage.contains("hidden") == true)

        manager.alertOnAppQuit = !origQuit
        #expect(manager.alertOnAppQuit == !origQuit)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("notifications") == true || manager.activityLogs.first?.userFriendlyMessage.contains("quit") == true)

        // Safe notification delivery check outside .app bundle
        manager.postUserNotification(title: "Test Alert", body: "Body text")
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Test Alert") == true)
    }

    @Test("Sleep, dark screen, lock screen, and screensaver multi-reason pause tracking")
    func testMultiReasonSessionPauseAndResume() {
        let manager = makeManager()
        #expect(manager.activePauseReasons.isEmpty)
        #expect(manager.sleepBeganDate == nil)

        // Simulate screensaver starting followed by screen locking
        manager.handleSessionPauseBegan(reason: "screensaver", friendlyDescription: "Screensaver started")
        #expect(manager.activePauseReasons.contains("screensaver"))
        #expect(manager.sleepBeganDate != nil)

        manager.handleSessionPauseBegan(reason: "screenLocked", friendlyDescription: "Screen locked")
        #expect(manager.activePauseReasons.count == 2)

        // Stopping screensaver while screen is still locked must keep timers paused
        manager.handleSessionPauseEnded(reason: "screensaver", friendlyDescription: "Screensaver stopped")
        #expect(manager.activePauseReasons.contains("screenLocked"))
        #expect(manager.sleepBeganDate != nil)

        // Unlocking screen clears remaining pause reason and resumes timers
        manager.handleSessionPauseEnded(reason: "screenLocked", friendlyDescription: "Screen unlocked")
        #expect(manager.activePauseReasons.isEmpty)
        #expect(manager.sleepBeganDate == nil)
    }

    @Test("Persistent diagnostic log file is created and written on disk")
    func testPersistentDiagnosticLogFile() async {
        let manager = makeManager()
        manager.appendLog(.info, "Unit test diagnostic check.", technical: "suite=AutoHideAgentTests")
        await manager.flushDiagnosticLog()
        let logURL = manager.logFileURL
        #expect(FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test("Global HID idle seconds and IOKit power assertions execute without error")
    func testSystemBridges() {
        let manager = makeManager()
        let idle = manager.currentHIDIdleSeconds()
        #expect(idle >= 0)

        let assertionPIDs = manager.activePowerAssertionPIDs()
        // Should return a valid Set<pid_t> (empty or non-empty depending on active system audio/video)
        #expect(assertionPIDs.count >= 0)
    }

    @Test("Dock and Menu Bar presence options toggle and prevent hiding both simultaneously")
    func testDockAndMenuBarPresenceOptions() {
        let manager = makeManager()
        let originalDock = manager.showInDock
        let originalMenuBar = manager.showInMenuBar
        defer {
            manager.showInDock = true
            manager.showInMenuBar = originalMenuBar
            manager.showInDock = originalDock
        }

        manager.showInDock = true
        manager.showInMenuBar = true

        // Turning off Dock while Menu Bar is on is allowed
        manager.showInDock = false
        #expect(manager.showInDock == false)
        #expect(manager.showInMenuBar == true)

        // Turning off Menu Bar when Dock is already off must automatically re-enable Dock so user never loses access
        manager.showInMenuBar = false
        #expect(manager.showInMenuBar == false)
        #expect(manager.showInDock == true)
    }

    @Test("Dev build and dry-run safe mode flags and log separation")
    func testDevBuildAndDryRunMode() {
        let manager = makeManager()
        let logURL = manager.logFileURL
        #expect(logURL.lastPathComponent.contains(".log"))

        // When dry-run is triggered via environment or flag, hiding is intercepted
        #expect(manager.isDryRunMode)
    }

    @Test("Invalid pause durations never crash or replace the active pause")
    func testInvalidPauseDurations() {
        let manager = makeManager()
        manager.pause(for: 3600)
        let until = manager.pausedUntilDate
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0, 43201, Double.greatestFiniteMagnitude] {
            manager.pause(for: invalid)
            #expect(manager.pausedUntilDate == until)
        }
    }

    @Test("Manual quit is intercepted before resolving the target or showing confirmation")
    func testManualQuitDryRun() {
        let manager = makeManager()
        manager.confirmBeforeAutoQuit = true
        let target = RunningAppInfo(pid: -1, bundleIdentifier: "test.target", localizedName: "Test Target",
            icon: nil, isHidden: false, isProtectedMostRecent: false, hasActivePowerAssertion: false,
            isWhitelisted: false, deactivatedSince: nil, elapsedInactiveSeconds: nil)
        manager.manuallyQuitApp(target)
        #expect(manager.activityLogs.first?.userFriendlyMessage == "[DRY RUN] Would manually quit Test Target.")
    }

    @Test("Release bundle identity stays production even when packaged under build")
    func testBundleIdentity() {
        #expect(!AppRuntime.isDevelopment(bundleIdentifier: "com.systems.autohideagent"))
        #expect(AppRuntime.isDevelopment(bundleIdentifier: "com.systems.autohideagent.dev"))
        #expect(!AppRuntime.isDevelopment(bundleIdentifier: "other.dev.app"))
    }

    @Test("Notification and pause settings persist in the injected preferences domain")
    func testSettingsPersistence() {
        let manager = makeManager()
        manager.alertOnAppHide = true
        manager.alertOnAppQuit = false
        manager.pauseDurationSeconds = 43200
        let reloaded = makeManager()
        #expect(reloaded.alertOnAppHide)
        #expect(!reloaded.alertOnAppQuit)
        #expect(reloaded.currentPausePreset == .twelveHours)
    }
    @Test("Expired snooze clears even when both automation features are off")
    func testPauseExpiryWithAutomationOff() async throws {
        let manager = makeManager()
        manager.isAutoHideEnabled = false
        manager.isAutoQuitEnabled = false
        manager.pause(for: 0.001)
        try await Task.sleep(for: .milliseconds(20))
        manager.evaluateAndHideInactiveApps()
        #expect(manager.pausedUntilDate == nil)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Resumed AutoHideAgent") == true)
    }

    @Test("An unavailable updater cannot claim automatic checks are enabled")
    func testUnavailableUpdaterSettings() {
        let updater = UpdateController.shared
        #expect(!updater.isUpdaterAvailable)
        #expect(!updater.canCheckForUpdates)
        updater.automaticallyChecksForUpdates = true
        #expect(!updater.automaticallyChecksForUpdates)
        updater.checkForUpdates()
    }

    @Test("Menu icon selection follows the panel and focused desktop independently")
    func testMenuBarSelectionAcrossPresentations() {
        var state = MenuBarPresentationState()
        #expect(!state.shouldHighlight(panelIsVisible: false, dashboardIsFocused: false))
        #expect(state.shouldHighlight(panelIsVisible: false, dashboardIsFocused: true))
        state.openPanel()
        #expect(state.shouldHighlight(panelIsVisible: true, dashboardIsFocused: false))
        #expect(!state.shouldHighlight(panelIsVisible: false, dashboardIsFocused: false))
        let close = state.beginClosingPanel()
        // A closing panel remains visible during its fade, but is no longer selected.
        #expect(!state.shouldHighlight(panelIsVisible: true, dashboardIsFocused: false))
        #expect(state.shouldHighlight(panelIsVisible: true, dashboardIsFocused: true))
        let didClose = state.finishClosingPanel(transitionID: close)
        #expect(didClose)
        #expect(state.shouldHighlight(panelIsVisible: false, dashboardIsFocused: true))
        #expect(!state.shouldHighlight(panelIsVisible: false, dashboardIsFocused: false))
    }

    @Test("A stale close animation cannot dismiss a reopened menu panel")
    func testMenuPanelReopenDuringClose() {
        var state = MenuBarPresentationState()
        state.openPanel()
        let oldClose = state.beginClosingPanel()
        state.openPanel()
        let staleCloseAccepted = state.finishClosingPanel(transitionID: oldClose)
        #expect(!staleCloseAccepted)
        #expect(state.shouldHighlight(panelIsVisible: true, dashboardIsFocused: false))
        let currentClose = state.beginClosingPanel()
        let secondStaleCloseAccepted = state.finishClosingPanel(transitionID: oldClose)
        #expect(!secondStaleCloseAccepted)
        let currentCloseAccepted = state.finishClosingPanel(transitionID: currentClose)
        #expect(currentCloseAccepted)
        #expect(!state.shouldHighlight(panelIsVisible: false, dashboardIsFocused: false))
    }

}
