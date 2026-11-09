import Foundation
import Testing
@testable import AutoHideAgent

@Suite("AutoHideAgent Core Logic & State Suite")
@MainActor
struct AutoHideAgentTests {

    @Test("TimeoutPreset and QuitTimeoutPreset values and labels match specifications")
    func testTimeoutPresets() {
        // Auto-Hide presets: 5m to 1h
        #expect(TimeoutPreset.allCases.map(\.rawValue) == [300, 600, 900, 1800, 3600])
        #expect(TimeoutPreset.allCases.map(\.label) == ["5m", "10m", "15m", "30m", "1h"])

        // Auto-Quit presets: 1h to 1d
        #expect(QuitTimeoutPreset.allCases.map(\.rawValue) == [3600, 7200, 21600, 43200, 86400])
        #expect(QuitTimeoutPreset.allCases.map(\.label) == ["1h", "2h", "6h", "12h", "1d"])
    }

    @Test("Friendly duration formatting produces clear everyday strings")
    func testFriendlyDurationFormatter() {
        let manager = AutoHideManager()
        #expect(manager.formatFriendlyDuration(45) == "45 sec")
        #expect(manager.formatFriendlyDuration(60) == "1 min")
        #expect(manager.formatFriendlyDuration(900) == "15 mins")
        #expect(manager.formatFriendlyDuration(3600) == "1 hr")
        #expect(manager.formatFriendlyDuration(7200) == "2 hrs")
        #expect(manager.formatFriendlyDuration(5400) == "1h 30m")
    }

    @Test("Whitelist management adds, deduplicates case-insensitively, removes, and logs events")
    func testWhitelistManagement() {
        let manager = AutoHideManager()
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
        let manager = AutoHideManager()
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
        let manager = AutoHideManager()
        #expect(manager.isTemporarilyPaused == false)

        manager.togglePauseForOneHour()
        #expect(manager.isTemporarilyPaused == true)
        #expect(manager.pausedUntilDate != nil)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Paused AutoHide for 1 hour") == true)

        manager.resumeFromTemporaryPause()
        #expect(manager.isTemporarilyPaused == false)
        #expect(manager.pausedUntilDate == nil)
        #expect(manager.activityLogs.first?.userFriendlyMessage.contains("Resumed AutoHide") == true)
    }

    @Test("Sleep, dark screen, lock screen, and screensaver multi-reason pause tracking")
    func testMultiReasonSessionPauseAndResume() {
        let manager = AutoHideManager()
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
    func testPersistentDiagnosticLogFile() {
        let manager = AutoHideManager()
        manager.appendLog(.info, "Unit test diagnostic check.", technical: "suite=AutoHideAgentTests")
        let logURL = manager.logFileURL
        #expect(FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test("Global HID idle seconds and IOKit power assertions execute without error")
    func testSystemBridges() {
        let manager = AutoHideManager()
        let idle = manager.currentHIDIdleSeconds()
        #expect(idle >= 0)

        let assertionPIDs = manager.activePowerAssertionPIDs()
        // Should return a valid Set<pid_t> (empty or non-empty depending on active system audio/video)
        #expect(assertionPIDs.count >= 0)
    }

    @Test("Dock and Menu Bar presence options toggle and prevent hiding both simultaneously")
    func testDockAndMenuBarPresenceOptions() {
        let manager = AutoHideManager()
        defer {
            manager.showInDock = true
            manager.showInMenuBar = true
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
}
