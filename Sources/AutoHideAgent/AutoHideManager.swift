import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Observation
import os.log
import ServiceManagement

private let logger = Logger(subsystem: "com.systems.autohideagent", category: "AutoHideManager")

// MARK: - Timeout Preset Models

public enum TimeoutPreset: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .fiveMinutes: return "5m"
        case .tenMinutes: return "10m"
        case .fifteenMinutes: return "15m"
        case .thirtyMinutes: return "30m"
        case .oneHour: return "1h"
        }
    }

    public var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }
}

public enum QuitTimeoutPreset: Int, CaseIterable, Identifiable, Sendable {
    case oneHour = 3600
    case twoHours = 7200
    case sixHours = 21600
    case twelveHours = 43200
    case oneDay = 86400

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .oneHour: return "1h"
        case .twoHours: return "2h"
        case .sixHours: return "6h"
        case .twelveHours: return "12h"
        case .oneDay: return "1d"
        }
    }

    public var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }
}

// MARK: - Activity Log Entry

public struct ActivityLogEntry: Identifiable, Sendable {
    public enum Level: String, Sendable {
        case info = "INFO"
        case warning = "NOTICE"
        case action = "ACTION"
    }

    public let id = UUID()
    public let timestamp: Date
    public let level: Level
    public let userFriendlyMessage: String
    public let technicalDetail: String
}

// MARK: - Running App Representation

public struct RunningAppInfo: Identifiable, Hashable, Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String
    public let localizedName: String
    public let icon: NSImage?
    public let isHidden: Bool
    public let isProtectedMostRecent: Bool
    public let hasActivePowerAssertion: Bool
    public let deactivatedSince: Date?
    public let elapsedInactiveSeconds: TimeInterval?

    public var id: String { bundleIdentifier }
}

/// Debug automation hooks (snapshots, tab switching) are only active when launched with AUTOHIDE_DEBUG=1.
public let autoHideDebugHooksEnabled = ProcessInfo.processInfo.environment["AUTOHIDE_DEBUG"] != nil

// MARK: - AutoHideManager (AutoHideController)

/// Coordinates event-driven application transition tracking, HID idle guards,
/// sleep/screensaver/lock awareness, media/power assertion protection,
/// and power-efficient background application hiding & quitting.
@MainActor
@Observable
public final class AutoHideManager {

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let isEnabled = "com.systems.autohideagent.isEnabled"
        static let isAutoHideEnabled = "com.systems.autohideagent.isAutoHideEnabled"
        static let timeoutSeconds = "com.systems.autohideagent.timeoutSeconds"
        static let isAutoQuitEnabled = "com.systems.autohideagent.isAutoQuitEnabled"
        static let quitTimeoutSeconds = "com.systems.autohideagent.quitTimeoutSeconds"
        static let confirmBeforeAutoQuit = "com.systems.autohideagent.confirmBeforeAutoQuit"
        static let keepPreviousAppVisible = "com.systems.autohideagent.keepPreviousAppVisible"
        static let protectActiveMediaApps = "com.systems.autohideagent.protectActiveMediaApps"
        static let showInDock = "com.systems.autohideagent.showInDock"
        static let showInMenuBar = "com.systems.autohideagent.showInMenuBar"
        static let whitelistedItems = "com.systems.autohideagent.whitelistedItems"
    }

    // MARK: - Persistent Properties

    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
            if !isEnabled {
                pausedUntilDate = nil
            }
            appendLog(
                .info,
                isEnabled ? "Turned AutoHideAgent Agent ON." : "Turned AutoHideAgent Agent OFF.",
                technical: "isEnabled=\(isEnabled)"
            )
            handleEnabledStateChange()
            onStateChange?()
        }
    }

    /// Independent toggle to enable/disable the Auto-Hide feature while keeping the daemon or Auto-Quit active.
    public var isAutoHideEnabled: Bool {
        didSet {
            guard isAutoHideEnabled != oldValue else { return }
            UserDefaults.standard.set(isAutoHideEnabled, forKey: Keys.isAutoHideEnabled)
            appendLog(
                .info,
                isAutoHideEnabled ? "Enabled Auto-Hide (\(formatFriendlyDuration(TimeInterval(timeoutSeconds))))." : "Disabled Auto-Hide.",
                technical: "isAutoHideEnabled=\(isAutoHideEnabled)"
            )
            if isEnabled && isAutoHideEnabled {
                evaluateAndHideInactiveApps()
            }
        }
    }

    public var timeoutSeconds: Int {
        didSet {
            guard timeoutSeconds != oldValue else { return }
            UserDefaults.standard.set(timeoutSeconds, forKey: Keys.timeoutSeconds)
            let label = TimeoutPreset(rawValue: timeoutSeconds)?.label ?? "\(timeoutSeconds / 60)m"
            appendLog(
                .info,
                "Changed Auto-Hide timer to \(label).",
                technical: "timeoutSeconds=\(timeoutSeconds)"
            )
            if isEnabled && isAutoHideEnabled {
                evaluateAndHideInactiveApps()
            }
        }
    }

    public var isAutoQuitEnabled: Bool {
        didSet {
            guard isAutoQuitEnabled != oldValue else { return }
            UserDefaults.standard.set(isAutoQuitEnabled, forKey: Keys.isAutoQuitEnabled)
            appendLog(
                .info,
                isAutoQuitEnabled ? "Enabled Auto-Quit (\(formatFriendlyDuration(TimeInterval(quitTimeoutSeconds))))." : "Disabled Auto-Quit.",
                technical: "isAutoQuitEnabled=\(isAutoQuitEnabled)"
            )
            if isEnabled && isAutoQuitEnabled {
                autoQuitAttemptedPIDs.removeAll()
                evaluateAndHideInactiveApps()
            }
        }
    }

    public var quitTimeoutSeconds: Int {
        didSet {
            guard quitTimeoutSeconds != oldValue else { return }
            UserDefaults.standard.set(quitTimeoutSeconds, forKey: Keys.quitTimeoutSeconds)
            let label = QuitTimeoutPreset(rawValue: quitTimeoutSeconds)?.label ?? "\(quitTimeoutSeconds / 3600)h"
            appendLog(
                .info,
                "Changed Auto-Quit timer to \(label).",
                technical: "quitTimeoutSeconds=\(quitTimeoutSeconds)"
            )
            if isEnabled && isAutoQuitEnabled {
                autoQuitAttemptedPIDs.removeAll()
                evaluateAndHideInactiveApps()
            }
        }
    }

    /// Prompts the user with a confirmation alert before automatically quitting an inactive app.
    public var confirmBeforeAutoQuit: Bool {
        didSet {
            guard confirmBeforeAutoQuit != oldValue else { return }
            UserDefaults.standard.set(confirmBeforeAutoQuit, forKey: Keys.confirmBeforeAutoQuit)
            appendLog(
                .info,
                confirmBeforeAutoQuit ? "Enabled confirmation before quitting apps." : "Disabled confirmation before quitting apps.",
                technical: "confirmBeforeAutoQuit=\(confirmBeforeAutoQuit)"
            )
        }
    }

    /// Keeps the single most-recently deactivated background app visible (great when switching between two apps).
    public var keepPreviousAppVisible: Bool {
        didSet {
            guard keepPreviousAppVisible != oldValue else { return }
            UserDefaults.standard.set(keepPreviousAppVisible, forKey: Keys.keepPreviousAppVisible)
            appendLog(
                .info,
                keepPreviousAppVisible ? "Keeping most recent background app visible." : "Turned off 'Keep most recent app visible'.",
                technical: "keepPreviousAppVisible=\(keepPreviousAppVisible)"
            )
            refreshRunningApps()
        }
    }

    /// Protects apps holding active audio/video/call/power assertions (e.g., Zoom, Spotify, VLC, active downloads).
    public var protectActiveMediaApps: Bool {
        didSet {
            guard protectActiveMediaApps != oldValue else { return }
            UserDefaults.standard.set(protectActiveMediaApps, forKey: Keys.protectActiveMediaApps)
            appendLog(
                .info,
                protectActiveMediaApps ? "Protecting apps playing audio/video or on calls." : "Turned off media & call protection.",
                technical: "protectActiveMediaApps=\(protectActiveMediaApps)"
            )
            refreshRunningApps()
        }
    }

    /// Controls whether the application appears in the macOS Dock & Cmd+Tab switcher (`.regular` vs `.accessory`).
    public var showInDock: Bool {
        didSet {
            guard showInDock != oldValue else { return }
            // Prevent hiding both Dock and Menu Bar simultaneously so the user never loses access to the app
            if !showInDock && !showInMenuBar {
                showInMenuBar = true
            }
            UserDefaults.standard.set(showInDock, forKey: Keys.showInDock)
            appendLog(
                .info,
                showInDock ? "Showing AutoHideAgent in the macOS Dock." : "Hid AutoHideAgent from the Dock (Menu Bar mode).",
                technical: "showInDock=\(showInDock)"
            )
            onAppearanceModeChange?()
        }
    }

    /// Controls whether the application displays its status icon in the macOS top-right Menu Bar.
    public var showInMenuBar: Bool {
        didSet {
            guard showInMenuBar != oldValue else { return }
            // Prevent hiding both Menu Bar and Dock simultaneously
            if !showInMenuBar && !showInDock {
                showInDock = true
            }
            UserDefaults.standard.set(showInMenuBar, forKey: Keys.showInMenuBar)
            appendLog(
                .info,
                showInMenuBar ? "Showing AutoHideAgent icon in the Menu Bar." : "Hid AutoHideAgent icon from the Menu Bar.",
                technical: "showInMenuBar=\(showInMenuBar)"
            )
            onAppearanceModeChange?()
        }
    }

    /// Stores whitelisted bundle identifiers (e.g., `com.apple.Safari`) or localized app names.
    public var whitelistedBundleIDs: [String] {
        didSet {
            UserDefaults.standard.set(whitelistedBundleIDs, forKey: Keys.whitelistedItems)
        }
    }

    // MARK: - Runtime State

    /// Tracks the exact timestamp each running `.regular` application transitioned to the background.
    public private(set) var lastDeactivatedDates: [pid_t: Date] = [:]

    /// Tracks PIDs for which we already issued a graceful `terminate()` in the current background session.
    private var autoQuitAttemptedPIDs: Set<pid_t> = []

    /// Tracks PIDs currently showing a confirmation dialog so we don't stack alerts.
    private var pendingQuitConfirmationPIDs: Set<pid_t> = []

    /// Tracks the monotonic awake uptime (`ProcessInfo.processInfo.systemUptime`) when each app
    /// transitioned to the background.
    private var lastDeactivatedUptimes: [pid_t: TimeInterval] = [:]

    /// The PID of the most recently deactivated `.regular` app (used for "Keep Previous App Visible").
    public private(set) var mostRecentBackgroundPID: pid_t?

    /// Records the timestamp when the Mac entered system sleep, display dark/off, screen lock, or screensaver.
    public private(set) var sleepBeganDate: Date?

    /// Tracks active reasons why timers are currently suspended (e.g. `screensDidSleep`, `screensaver`, `screenLocked`).
    public private(set) var activePauseReasons: Set<String> = []

    /// If non-nil, temporary snooze ("Pause for 1 Hour") is active until this date.
    public private(set) var pausedUntilDate: Date?

    /// Live snapshot of running `.regular` apps for UI consumption.
    public private(set) var runningRegularApps: [RunningAppInfo] = []

    /// Current Launch at Login status from `SMAppService.mainApp`.
    public private(set) var launchAtLoginEnabled: Bool = false

    /// Last error message from `SMAppService` registration, if any.
    public private(set) var launchAtLoginError: String?

    /// Whether the process currently holds Accessibility permissions.
    public private(set) var isAccessibilityTrusted: Bool = false

    /// Recent activity logs displayed directly inside the app's UI popover (capped at 50 entries).
    public private(set) var activityLogs: [ActivityLogEntry] = []

    /// Optional callback invoked when `isEnabled` or snooze state changes so `AppDelegate` can update the status bar icon.
    public var onStateChange: (() -> Void)?

    /// Optional callback invoked when `showInDock` or `showInMenuBar` changes so `AppDelegate` can update activation policy & status item.
    public var onAppearanceModeChange: (() -> Void)?

    // MARK: - Private Machinery

    private var evaluationTimer: Timer?
    private var accessibilityPollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    /// Periodic timer interval (15 seconds) with 5-second tolerance for macOS timer coalescing.
    private let timerInterval: TimeInterval = 15.0
    private let timerTolerance: TimeInterval = 5.0

    /// In-memory application icon cache to eliminate disk lookups and image decoding during periodic ticks.
    private var iconCache: [String: NSImage] = [:]

    // MARK: - Initialization

    public init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.isEnabled: true,
            Keys.isAutoHideEnabled: true,
            Keys.timeoutSeconds: TimeoutPreset.fifteenMinutes.rawValue,
            Keys.isAutoQuitEnabled: false,
            Keys.quitTimeoutSeconds: QuitTimeoutPreset.twoHours.rawValue,
            Keys.confirmBeforeAutoQuit: true,
            Keys.keepPreviousAppVisible: false,
            Keys.protectActiveMediaApps: true,
            Keys.showInDock: true,
            Keys.showInMenuBar: false,
            Keys.whitelistedItems: [
                "com.apple.finder"
            ]
        ])

        self.isEnabled = defaults.bool(forKey: Keys.isEnabled)
        self.isAutoHideEnabled = defaults.bool(forKey: Keys.isAutoHideEnabled)
        let savedTimeout = defaults.integer(forKey: Keys.timeoutSeconds)
        self.timeoutSeconds = TimeoutPreset(rawValue: savedTimeout)?.rawValue ?? TimeoutPreset.fifteenMinutes.rawValue
        self.isAutoQuitEnabled = defaults.bool(forKey: Keys.isAutoQuitEnabled)
        let savedQuitTimeout = defaults.integer(forKey: Keys.quitTimeoutSeconds)
        self.quitTimeoutSeconds = QuitTimeoutPreset(rawValue: savedQuitTimeout)?.rawValue ?? QuitTimeoutPreset.twoHours.rawValue
        self.confirmBeforeAutoQuit = defaults.bool(forKey: Keys.confirmBeforeAutoQuit)
        self.keepPreviousAppVisible = defaults.bool(forKey: Keys.keepPreviousAppVisible)
        self.protectActiveMediaApps = defaults.bool(forKey: Keys.protectActiveMediaApps)
        self.showInDock = defaults.bool(forKey: Keys.showInDock)
        self.showInMenuBar = defaults.bool(forKey: Keys.showInMenuBar)
        self.whitelistedBundleIDs = defaults.stringArray(forKey: Keys.whitelistedItems) ?? ["com.apple.finder"]

        seedInitialBackgroundTimestamps()
        setupWorkspaceNotifications()
        setupScreenLockAndScreensaverNotifications()
        refreshRunningApps()
        refreshLaunchAtLoginStatus()
        refreshAccessibilityTrustStatus(promptIfNeeded: false)
        startAccessibilityTrustPollingIfNeeded()
        appendLog(
            .info,
            "AutoHideAgent is running and watching background apps.",
            technical: "init() completed; AX=\(isAccessibilityTrusted), autoHide=\(isAutoHideEnabled) (\(timeoutSeconds)s), autoQuit=\(isAutoQuitEnabled) (\(quitTimeoutSeconds)s), confirmQuit=\(confirmBeforeAutoQuit), keepPrev=\(keepPreviousAppVisible), protectMedia=\(protectActiveMediaApps)"
        )
        handleEnabledStateChange()
    }

    // MARK: - Temporary Snooze ("Pause for 1 Hour")

    public var isTemporarilyPaused: Bool {
        guard let until = pausedUntilDate else { return false }
        return Date.now < until
    }

    public func togglePauseForOneHour() {
        if isTemporarilyPaused {
            resumeFromTemporaryPause()
        } else {
            let until = Date.now.addingTimeInterval(3600)
            pausedUntilDate = until
            appendLog(.info, "Paused AutoHideAgent for 1 hour.", technical: "pausedUntil=\(Self.isoFormatter.string(from: until))")
            onStateChange?()
        }
    }

    public func resumeFromTemporaryPause() {
        guard pausedUntilDate != nil else { return }
        pausedUntilDate = nil
        // Reset background timestamps to now so apps aren't immediately hidden on unpause
        seedInitialBackgroundTimestamps()
        appendLog(.info, "Resumed AutoHideAgent from temporary pause.", technical: "manual/auto resume")
        onStateChange?()
        refreshRunningApps()
    }

    // MARK: - Instant "Hide Background Apps Now" Action

    /// Number of currently visible (unhidden) background `.regular` applications that are eligible to be hidden.
    public var visibleBackgroundAppsCount: Int {
        runningRegularApps.filter { app in
            !app.isHidden && !whitelistedBundleIDs.contains {
                $0.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame ||
                $0.caseInsensitiveCompare(app.localizedName) == .orderedSame
            }
        }.count
    }

    /// Number of currently hidden background `.regular` applications.
    public var hiddenBackgroundAppsCount: Int {
        runningRegularApps.filter { $0.isHidden }.count
    }

    /// Immediately hides all currently visible, non-whitelisted background `.regular` applications.
    public func hideAllBackgroundAppsNow() {
        guard checkAccessibilityPermissions(promptIfNeeded: false) else { return }
        refreshAccessibilityTrustStatus(promptIfNeeded: false)
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let myPID = ProcessInfo.processInfo.processIdentifier
        let protectedAssertions = protectActiveMediaApps ? activePowerAssertionPIDs() : []
        var hiddenCount = 0
        var eligibleCount = 0
        var blockedByAX = false

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  !app.isTerminated,
                  app != frontmostApp,
                  pid != myPID,
                  app.bundleIdentifier != "com.apple.finder",
                  !isAppWhitelisted(app) else {
                continue
            }

            if keepPreviousAppVisible, pid == mostRecentBackgroundPID { continue }
            if protectActiveMediaApps, protectedAssertions.contains(pid) { continue }

            eligibleCount += 1

            if app.hide() {
                hiddenCount += 1
            } else {
                let axOutcome = hideViaAccessibilityIfTrusted(pid: pid)
                switch axOutcome {
                case .hidden:
                    hiddenCount += 1
                case .notTrusted:
                    blockedByAX = true
                case .failed:
                    break
                }
            }
        }

        if hiddenCount > 0 {
            appendLog(
                .action,
                "Hid \(hiddenCount) background \(hiddenCount == 1 ? "app" : "apps") right away.",
                technical: "manual hideAllBackgroundAppsNow() count=\(hiddenCount)/\(eligibleCount)"
            )
        } else if blockedByAX && eligibleCount > 0 {
            appendLog(
                .warning,
                "Grant Accessibility permission so AutoHideAgent can hide \(eligibleCount) background \(eligibleCount == 1 ? "app" : "apps").",
                technical: "manual hideAllBackgroundAppsNow() blocked: AXIsProcessTrusted=false, eligible=\(eligibleCount)"
            )
        } else {
            appendLog(
                .info,
                "All background apps are already hidden.",
                technical: "manual hideAllBackgroundAppsNow() count=0, eligible=0"
            )
        }
        refreshRunningApps()
    }

    // MARK: - Manual Per-App Hide & Quit Actions

    /// Manually hides a specific running application from the list and logs the event.
    public func manuallyHideApp(_ appInfo: RunningAppInfo) {
        guard let runningApp = NSRunningApplication(processIdentifier: appInfo.pid) else { return }
        if runningApp.hide() {
            appendLog(
                .action,
                "Manually hid \(appInfo.localizedName).",
                technical: "manual hide pid=\(appInfo.pid) bundleID=\(appInfo.bundleIdentifier) method=NSRunningApplication.hide()"
            )
        } else {
            let axOutcome = hideViaAccessibilityIfTrusted(pid: appInfo.pid)
            switch axOutcome {
            case .hidden:
                appendLog(
                    .action,
                    "Manually hid \(appInfo.localizedName).",
                    technical: "manual hide pid=\(appInfo.pid) bundleID=\(appInfo.bundleIdentifier) method=AXUIElement"
                )
            case .notTrusted:
                appendLog(
                    .warning,
                    "Needs Accessibility permission to hide \(appInfo.localizedName).",
                    technical: "manual hide failed: AXIsProcessTrusted=false"
                )
            case .failed(let axError):
                appendLog(
                    .warning,
                    "Couldn't hide \(appInfo.localizedName).",
                    technical: "manual hide failed: AXError=\(axError.rawValue)"
                )
            }
        }
        refreshRunningApps()
    }

    /// Manually quits a specific running application from the list (respecting confirmation if enabled) and logs the event.
    public func manuallyQuitApp(_ appInfo: RunningAppInfo) {
        guard let runningApp = NSRunningApplication(processIdentifier: appInfo.pid) else { return }
        if confirmBeforeAutoQuit {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Quit \"\(appInfo.localizedName)\"?"
            alert.informativeText = "Are you sure you want to quit \(appInfo.localizedName) right now?"
            if let icon = appInfo.icon {
                alert.icon = icon
            }
            alert.addButton(withTitle: "Quit \(appInfo.localizedName)")
            alert.addButton(withTitle: "Cancel")

            NSApplication.shared.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                appendLog(
                    .info,
                    "Cancelled quitting \(appInfo.localizedName).",
                    technical: "manual quit cancelled by user for pid=\(appInfo.pid)"
                )
                return
            }
        }

        let didTerminate = runningApp.terminate()
        if didTerminate {
            appendLog(
                .action,
                "Manually quit \(appInfo.localizedName).",
                technical: "manual terminate() succeeded for pid=\(appInfo.pid) bundleID=\(appInfo.bundleIdentifier)"
            )
        } else {
            appendLog(
                .warning,
                "Couldn't quit \(appInfo.localizedName) — it may have unsaved changes.",
                technical: "manual terminate() returned false for pid=\(appInfo.pid)"
            )
        }
        refreshRunningApps()
    }

    // MARK: - In-App & Persistent File Logger

    /// Path to the persistent diagnostic log file (`~/Library/Logs/AutoHideAgent/AutoHideAgent.log`).
    public var logFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsDir = home.appendingPathComponent("Library/Logs/AutoHideAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("AutoHideAgent.log", isDirectory: false)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Formats a duration in seconds into a friendly string for everyday users (e.g., "15 mins", "2 hrs").
    public nonisolated func formatFriendlyDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(round(seconds)))
        if totalSeconds < 60 {
            return "\(totalSeconds) sec"
        }
        let minutes = totalSeconds / 60
        if minutes < 60 {
            return minutes == 1 ? "1 min" : "\(minutes) mins"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if remMinutes == 0 {
            return hours == 1 ? "1 hr" : "\(hours) hrs"
        }
        return "\(hours)h \(remMinutes)m"
    }

    /// Appends a friendly message to the in-app Activity Log and writes a detailed diagnostic line
    /// to `~/Library/Logs/AutoHideAgent/AutoHideAgent.log` so the user can share or inspect it with 1 click.
    public func appendLog(_ level: ActivityLogEntry.Level, _ userFriendlyMessage: String, technical: String = "") {
        let now = Date.now
        let entry = ActivityLogEntry(
            timestamp: now,
            level: level,
            userFriendlyMessage: userFriendlyMessage,
            technicalDetail: technical
        )
        activityLogs.insert(entry, at: 0)
        if activityLogs.count > 50 {
            activityLogs.removeLast(activityLogs.count - 50)
        }

        let fullLogLine = "[\(Self.isoFormatter.string(from: now))] [\(level.rawValue)] \(userFriendlyMessage)" + (technical.isEmpty ? "\n" : " | diag: \(technical)\n")
        writeToPersistentLogFile(fullLogLine)

        switch level {
        case .info:
            logger.info("\(userFriendlyMessage, privacy: .public) [\(technical, privacy: .public)]")
        case .warning:
            logger.notice("\(userFriendlyMessage, privacy: .public) [\(technical, privacy: .public)]")
        case .action:
            logger.info("[ACTION] \(userFriendlyMessage, privacy: .public) [\(technical, privacy: .public)]")
        }
    }

    private func writeToPersistentLogFile(_ line: String) {
        let url = logFileURL
        guard let data = line.data(using: .utf8) else { return }
        // Rotate at 1 MB so the diagnostic log never grows without bound
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            let header = """
            ================================================================================
            AutoHideAgent Diagnostic Log
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Bundle ID: \(Bundle.main.bundleIdentifier ?? "com.systems.autohideagent")
            ================================================================================
            
            """
            let combined = (header.data(using: .utf8) ?? Data()) + data
            try? combined.write(to: url, options: .atomic)
        }
    }

    public func openDiagnosticLogFile() {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            appendLog(.info, "Created diagnostic log file.", technical: "path=\(url.path)")
        }
        let snapshot = "[\(Self.isoFormatter.string(from: Date.now))] [SNAPSHOT] Enabled=\(isEnabled), PausedUntil=\(String(describing: pausedUntilDate)), HideTimeout=\(timeoutSeconds)s, AutoQuit=\(isAutoQuitEnabled) (\(quitTimeoutSeconds)s), ConfirmQuit=\(confirmBeforeAutoQuit), KeepPrev=\(keepPreviousAppVisible), ProtectMedia=\(protectActiveMediaApps), AXTrusted=\(isAccessibilityTrusted), HIDIdle=\(String(format: "%.1f", currentHIDIdleSeconds()))s, ActivePauseReasons=\(activePauseReasons), TrackedApps=\(lastDeactivatedDates.count), Whitelist=\(whitelistedBundleIDs)\n"
        writeToPersistentLogFile(snapshot)
        NSWorkspace.shared.open(url)
    }

    public func revealDiagnosticLogInFinder() {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            appendLog(.info, "Created diagnostic log file.", technical: "path=\(url.path)")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func clearLogs() {
        activityLogs.removeAll()
    }

    // MARK: - Event-Driven State Tracking

    private func seedInitialBackgroundTimestamps() {
        let now = Date.now
        let uptime = ProcessInfo.processInfo.systemUptime
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  app.processIdentifier != frontmostPID,
                  app.processIdentifier != myPID else {
                continue
            }
            lastDeactivatedDates[app.processIdentifier] = now
            lastDeactivatedUptimes[app.processIdentifier] = uptime
        }
    }

    /// Pauses inactivity countdowns when the Mac sleeps, screen turns off/dark, screen locks, or screensaver starts.
    public func handleSessionPauseBegan(reason: String, friendlyDescription: String) {
        activePauseReasons.insert(reason)
        if sleepBeganDate == nil {
            sleepBeganDate = Date.now
            appendLog(
                .info,
                "\(friendlyDescription) — paused all app timers.",
                technical: "pauseReason=\(reason), activeReasons=\(activePauseReasons)"
            )
        }
        stopEvaluationTimer()
    }

    /// Resumes inactivity countdowns when all sleep/dark-screen/screensaver/lock conditions have cleared,
    /// shifting all background timestamps forward by the exact paused duration.
    public func handleSessionPauseEnded(reason: String, friendlyDescription: String) {
        activePauseReasons.remove(reason)
        // If another pause condition is still active (e.g., screen woke briefly while still locked), stay paused
        guard activePauseReasons.isEmpty else { return }

        if let sleepStart = sleepBeganDate {
            let pausedDuration = max(0, Date.now.timeIntervalSince(sleepStart))
            sleepBeganDate = nil

            for (pid, deactivatedDate) in lastDeactivatedDates {
                lastDeactivatedDates[pid] = deactivatedDate.addingTimeInterval(pausedDuration)
            }
            for (pid, deactivatedUptime) in lastDeactivatedUptimes {
                // Also advance monotonic uptime baseline if the Mac stayed awake during screensaver/screen-off
                lastDeactivatedUptimes[pid] = min(ProcessInfo.processInfo.systemUptime, deactivatedUptime + pausedDuration)
            }
            appendLog(
                .info,
                "\(friendlyDescription) after \(formatFriendlyDuration(pausedDuration)) — resumed timers.",
                technical: "resumeReason=\(reason), pausedDuration=\(String(format: "%.1f", pausedDuration))s, shiftedApps=\(lastDeactivatedDates.count)"
            )
        }

        if isEnabled {
            startEvaluationTimer()
        }
        refreshRunningApps()
    }

    /// Subscribes to `NSWorkspace.shared.notificationCenter` for application lifecycle, sleep, and display-off transitions.
    private func setupWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        // 0. AutoHideAgent became active (user switched back from System Settings or another app)
        let appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                }
            }
        }

        // 1. Application became active (frontmost)
        let activateObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid {
                    self.lastDeactivatedDates.removeValue(forKey: pid)
                    self.lastDeactivatedUptimes.removeValue(forKey: pid)
                    self.autoQuitAttemptedPIDs.remove(pid)
                    if self.mostRecentBackgroundPID == pid {
                        self.recomputeMostRecentBackgroundPID()
                    }
                }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                }
                self.refreshRunningApps()
            }
        }

        // 2. Application resigned active (transitioned to background)
        let deactivateObserver = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let isRegular = app?.activationPolicy == .regular
            let isTerminated = app?.isTerminated ?? true
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid, isRegular, !isTerminated {
                    self.lastDeactivatedDates[pid] = Date.now
                    self.lastDeactivatedUptimes[pid] = ProcessInfo.processInfo.systemUptime
                    self.autoQuitAttemptedPIDs.remove(pid)
                    if bundleID != "com.apple.finder" && pid != ProcessInfo.processInfo.processIdentifier {
                        self.mostRecentBackgroundPID = pid
                    }
                }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                }
                self.refreshRunningApps()
            }
        }

        // 3. Application terminated
        let terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid {
                    self.lastDeactivatedDates.removeValue(forKey: pid)
                    self.lastDeactivatedUptimes.removeValue(forKey: pid)
                    self.autoQuitAttemptedPIDs.remove(pid)
                    self.pendingQuitConfirmationPIDs.remove(pid)
                    if self.mostRecentBackgroundPID == pid {
                        self.recomputeMostRecentBackgroundPID()
                    }
                }
                if let bundleID {
                    self.iconCache.removeValue(forKey: bundleID)
                }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                }
                self.refreshRunningApps()
            }
        }

        // 4. Application launched
        let launchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let isRegular = app?.activationPolicy == .regular
            let isActive = app?.isActive ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid, isRegular, !isActive {
                    self.lastDeactivatedDates[pid] = Date.now
                    self.lastDeactivatedUptimes[pid] = ProcessInfo.processInfo.systemUptime
                }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                }
                self.refreshRunningApps()
            }
        }

        // 5. Application hidden/unhidden
        let hideObserver = nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshRunningApps()
            }
        }

        let unhideObserver = nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let appName = app?.localizedName ?? app?.bundleIdentifier ?? "App"
            let isActive = app?.isActive ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid, !isActive {
                    self.lastDeactivatedDates[pid] = Date.now
                    self.lastDeactivatedUptimes[pid] = ProcessInfo.processInfo.systemUptime
                    self.appendLog(
                        .info,
                        "\(appName) was shown again — reset its timer.",
                        technical: "didUnhideApplication pid=\(pid)"
                    )
                }
                self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                self.refreshRunningApps()
            }
        }

        // 6. System Sleep & Display Off (Dark Screen / Lid Closed)
        let willSleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionPauseBegan(reason: "systemSleep", friendlyDescription: "Mac went to sleep")
            }
        }

        let didWakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activePauseReasons.remove("systemSleep")
                self?.handleSessionPauseEnded(reason: "systemSleep", friendlyDescription: "Mac woke up")
            }
        }

        let screensDidSleepObserver = nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionPauseBegan(reason: "displayDark", friendlyDescription: "Screen turned off")
            }
        }

        let screensDidWakeObserver = nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionPauseEnded(reason: "displayDark", friendlyDescription: "Screen turned on")
            }
        }

        workspaceObservers = [
            appActiveObserver,
            activateObserver,
            deactivateObserver,
            terminateObserver,
            launchObserver,
            hideObserver,
            unhideObserver,
            willSleepObserver,
            didWakeObserver,
            screensDidSleepObserver,
            screensDidWakeObserver
        ]
    }

    /// Subscribes to `DistributedNotificationCenter` for macOS Screensaver and Lock Screen events.
    private func setupScreenLockAndScreensaverNotifications() {
        let dnc = DistributedNotificationCenter.default()

        let saverStart = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionPauseBegan(reason: "screensaver", friendlyDescription: "Screensaver started")
            }
        }

        let saverStop = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionPauseEnded(reason: "screensaver", friendlyDescription: "Screensaver stopped")
            }
        }

        let screenLocked = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionPauseBegan(reason: "screenLocked", friendlyDescription: "Screen locked")
            }
        }

        let screenUnlocked = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Clear both screenLocked and any lingering screensaver flag on unlock
                self?.activePauseReasons.remove("screensaver")
                self?.handleSessionPauseEnded(reason: "screenLocked", friendlyDescription: "Screen unlocked")
            }
        }

        distributedObservers = [saverStart, saverStop, screenLocked, screenUnlocked]
    }

    private func recomputeMostRecentBackgroundPID() {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        mostRecentBackgroundPID = lastDeactivatedDates
            .filter { $0.key != frontmostPID && $0.key != myPID }
            .max(by: { $0.value < $1.value })?.key
    }

    // MARK: - IOKit Power / Media / Call Assertion Detection

    /// Queries `IOPMCopyAssertionsByProcess` to identify PIDs currently holding active audio, video,
    /// conference call, or background task power assertions (e.g. Spotify, Apple Music, Zoom, VLC).
    public nonisolated func activePowerAssertionPIDs() -> Set<pid_t> {
        var assertionsByPID: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByPID)
        guard status == kIOReturnSuccess,
              let dict = assertionsByPID?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }

        let protectedAssertionTypes: Set<String> = [
            "PreventUserIdleDisplaySleep",
            "PreventUserIdleSystemSleep",
            "NoDisplaySleepAssertion",
            "NoIdleSleepAssertion",
            "audio-out",
            "audio-in"
        ]

        var pids = Set<pid_t>()
        for (pidNumber, assertions) in dict {
            for assertion in assertions {
                if let type = assertion["AssertType"] as? String,
                   protectedAssertionTypes.contains(type) {
                    pids.insert(pid_t(pidNumber.int32Value))
                    break
                }
            }
        }
        return pids
    }

    // MARK: - Power-Efficient Periodic Evaluation

    private func handleEnabledStateChange() {
        if isEnabled {
            seedInitialBackgroundTimestamps()
            startEvaluationTimer()
        } else {
            stopEvaluationTimer()
        }
    }

    private func startEvaluationTimer() {
        stopEvaluationTimer()

        let timer = Timer(timeInterval: timerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateAndHideInactiveApps()
            }
        }
        timer.tolerance = timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.evaluationTimer = timer
    }

    private func stopEvaluationTimer() {
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }

    // MARK: - Global HID Idle Guard & Execution

    public func currentHIDIdleSeconds() -> TimeInterval {
        guard let anyInputEventType = CGEventType(rawValue: ~0) else {
            return 0
        }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
    }

    /// Evaluates all running applications and hides or gracefully quits eligible background apps
    /// that have exceeded their configured inactivity thresholds while the user is actively
    /// interacting with the system.
    public func evaluateAndHideInactiveApps() {
        guard isEnabled, isAccessibilityTrusted else { return }
        guard isAutoHideEnabled || isAutoQuitEnabled else { return }

        // Check if "Pause for 1 Hour" snooze has expired or is still active
        if let until = pausedUntilDate {
            if Date.now >= until {
                resumeFromTemporaryPause()
            } else {
                return
            }
        }

        // Do not evaluate while the system, display, screensaver, or lock screen is active
        guard sleepBeganDate == nil && activePauseReasons.isEmpty else {
            return
        }

        // Secondary hardware check: if main display is asleep at the CoreGraphics level, pause
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            handleSessionPauseBegan(reason: "displayDark", friendlyDescription: "Screen turned off")
            return
        }

        let hideThreshold = TimeInterval(timeoutSeconds)
        let quitThreshold = TimeInterval(quitTimeoutSeconds)

        // Global HID Idle Guard:
        let idleSeconds = currentHIDIdleSeconds()
        let activeGuardThreshold: TimeInterval
        if isAutoHideEnabled && isAutoQuitEnabled {
            activeGuardThreshold = min(hideThreshold, quitThreshold)
        } else if isAutoQuitEnabled {
            activeGuardThreshold = quitThreshold
        } else {
            activeGuardThreshold = hideThreshold
        }
        guard idleSeconds < activeGuardThreshold else {
            return
        }

        let now = Date.now
        let currentUptime = ProcessInfo.processInfo.systemUptime
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let myPID = ProcessInfo.processInfo.processIdentifier
        let protectedAssertions = protectActiveMediaApps ? activePowerAssertionPIDs() : []

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier

            // 1. Must be a standard user-facing application (.regular)
            guard app.activationPolicy == .regular else { continue }

            // 2. Must not be terminated
            guard app.isTerminated == false else { continue }

            // 3. Must not be the frontmost application (or ourselves)
            guard app != frontmostApp, pid != myPID else {
                lastDeactivatedDates.removeValue(forKey: pid)
                lastDeactivatedUptimes.removeValue(forKey: pid)
                autoQuitAttemptedPIDs.remove(pid)
                continue
            }

            // 4. Never auto-hide or auto-quit Finder
            guard app.bundleIdentifier != "com.apple.finder" else { continue }

            // 5. Must not match the user's whitelist (by bundleIdentifier or localizedName)
            guard !isAppWhitelisted(app) else { continue }

            // 6. Smart Media / Call / Power Assertion Protection
            if protectActiveMediaApps && protectedAssertions.contains(pid) {
                continue
            }

            // 7. Must have a recorded deactivation timestamp
            guard let lastDeactivatedDate = lastDeactivatedDates[pid] else {
                lastDeactivatedDates[pid] = now
                lastDeactivatedUptimes[pid] = currentUptime
                continue
            }

            let wallAdjustedElapsed = now.timeIntervalSince(lastDeactivatedDate)
            let uptimeElapsed = lastDeactivatedUptimes[pid].map { currentUptime - $0 } ?? wallAdjustedElapsed
            let inactiveDuration = max(0, min(wallAdjustedElapsed, uptimeElapsed))
            let appName = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"

            // 8A. Auto-Quit Evaluation (works even if the app was previously auto-hidden)
            if isAutoQuitEnabled,
               idleSeconds < quitThreshold,
               inactiveDuration >= quitThreshold,
               !autoQuitAttemptedPIDs.contains(pid),
               !pendingQuitConfirmationPIDs.contains(pid) {

                let friendlyTime = formatFriendlyDuration(inactiveDuration)
                if confirmBeforeAutoQuit {
                    promptAndConfirmAutoQuit(for: app, appName: appName, friendlyTime: friendlyTime, inactiveDuration: inactiveDuration)
                } else {
                    autoQuitAttemptedPIDs.insert(pid)
                    performGracefulQuit(for: app, appName: appName, friendlyTime: friendlyTime, inactiveDuration: inactiveDuration)
                }
                continue
            }

            // 8B. "Keep Previous App Visible" check before hiding
            if keepPreviousAppVisible && pid == mostRecentBackgroundPID {
                continue
            }

            // 8C. Auto-Hide Evaluation (only if Auto-Hide is enabled and app is not already hidden)
            guard isAutoHideEnabled else { continue }
            guard app.isHidden == false else { continue }
            guard idleSeconds < hideThreshold, inactiveDuration >= hideThreshold else { continue }

            let friendlyTime = formatFriendlyDuration(inactiveDuration)
            let didHide = app.hide()
            if didHide {
                appendLog(
                    .action,
                    "Hid \(appName) (unused for \(friendlyTime)).",
                    technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s, method=NSRunningApplication.hide()"
                )
            } else {
                let axOutcome = hideViaAccessibilityIfTrusted(pid: pid)
                switch axOutcome {
                case .hidden:
                    appendLog(
                        .action,
                        "Hid \(appName) (unused for \(friendlyTime)).",
                        technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s, method=AXUIElement(kAXHiddenAttribute)"
                    )
                case .notTrusted:
                    appendLog(
                        .warning,
                        "Needs Accessibility permission to hide \(appName).",
                        technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), NSRunningApplication.hide()=false, AXIsProcessTrusted=false"
                    )
                case .failed(let axError):
                    appendLog(
                        .warning,
                        "Couldn't hide \(appName) right now.",
                        technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), AXError=\(axError.rawValue)"
                    )
                }
            }
        }

        refreshRunningApps()
    }

    // MARK: - Auto-Quit Confirmation & Execution

    private func performGracefulQuit(
        for app: NSRunningApplication,
        appName: String,
        friendlyTime: String,
        inactiveDuration: TimeInterval
    ) {
        let pid = app.processIdentifier
        let didTerminate = app.terminate()
        if didTerminate {
            appendLog(
                .action,
                "Quit \(appName) (unused for \(friendlyTime)).",
                technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s, method=terminate()"
            )
        } else {
            appendLog(
                .warning,
                "Couldn't quit \(appName) — it may have unsaved changes.",
                technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), terminate() returned false"
            )
        }
    }

    /// Presents a native macOS confirmation dialog before quitting an inactive app,
    /// allowing the user to Quit Now, Keep Open (reset timer), or Exclude Forever.
    private func promptAndConfirmAutoQuit(
        for app: NSRunningApplication,
        appName: String,
        friendlyTime: String,
        inactiveDuration: TimeInterval
    ) {
        let pid = app.processIdentifier
        pendingQuitConfirmationPIDs.insert(pid)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Quit Inactive App \"\(appName)\"?"
        alert.informativeText = "\(appName) has been unused in the background for \(friendlyTime). Would you like AutoHideAgent to quit it now?"
        if let appIcon = app.icon {
            alert.icon = appIcon
        }
        alert.addButton(withTitle: "Quit \(appName)")
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Always Exclude \(appName)")

        // Bring the alert to the front without stealing permanent focus
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        pendingQuitConfirmationPIDs.remove(pid)

        switch response {
        case .alertFirstButtonReturn:
            autoQuitAttemptedPIDs.insert(pid)
            performGracefulQuit(for: app, appName: appName, friendlyTime: friendlyTime, inactiveDuration: inactiveDuration)

        case .alertSecondButtonReturn:
            // Reset timer so it gets another full cycle
            lastDeactivatedDates[pid] = Date.now
            lastDeactivatedUptimes[pid] = ProcessInfo.processInfo.systemUptime
            autoQuitAttemptedPIDs.remove(pid)
            appendLog(
                .info,
                "Kept \(appName) open — reset its inactivity timer.",
                technical: "user chose Keep Open for pid=\(pid)"
            )

        case .alertThirdButtonReturn:
            let identifier = app.bundleIdentifier ?? appName
            addWhitelistEntry(identifier)
            appendLog(
                .info,
                "Added \(appName) to Exclusions.",
                technical: "user chose Always Exclude (\(identifier))"
            )

        default:
            break
        }
        refreshRunningApps()
    }

    // MARK: - Whitelist & Running Apps Management

    public func isAppWhitelisted(_ app: NSRunningApplication) -> Bool {
        let whitelistSet = Set(whitelistedBundleIDs.map { $0.lowercased() })
        if let bundleID = app.bundleIdentifier?.lowercased(), whitelistSet.contains(bundleID) {
            return true
        }
        if let name = app.localizedName?.lowercased(), whitelistSet.contains(name) {
            return true
        }
        return false
    }

    public func addWhitelistEntry(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let exists = whitelistedBundleIDs.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard !exists else { return }
        whitelistedBundleIDs.append(trimmed)
        let friendlyName = runningRegularApps.first {
            $0.bundleIdentifier.caseInsensitiveCompare(trimmed) == .orderedSame
        }?.localizedName ?? trimmed
        appendLog(
            .info,
            "Added \(friendlyName) to Exclusions.",
            technical: "addWhitelistEntry(\(trimmed))"
        )
        refreshRunningApps()
    }

    public func removeWhitelistEntry(_ identifier: String) {
        let friendlyName = runningRegularApps.first {
            $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
        }?.localizedName ?? identifier
        whitelistedBundleIDs.removeAll { $0.caseInsensitiveCompare(identifier) == .orderedSame }
        appendLog(
            .info,
            "Removed \(friendlyName) from Exclusions.",
            technical: "removeWhitelistEntry(\(identifier))"
        )
        refreshRunningApps()
    }

    public func refreshRunningApps() {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier
        let now = Date.now
        let currentUptime = ProcessInfo.processInfo.systemUptime
        let assertionPIDs = protectActiveMediaApps ? activePowerAssertionPIDs() : []

        let apps: [RunningAppInfo] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  let bundleID = app.bundleIdentifier,
                  bundleID != myBundleID,
                  bundleID != "com.apple.finder" else {
                return nil
            }
            let pid = app.processIdentifier
            let name = app.localizedName ?? bundleID
            let deactivated = (pid == frontmostPID) ? nil : lastDeactivatedDates[pid]
            var elapsed: TimeInterval? = nil
            if let deactivated {
                let wallElapsed = now.timeIntervalSince(deactivated)
                let upElapsed = lastDeactivatedUptimes[pid].map { currentUptime - $0 } ?? wallElapsed
                elapsed = max(0, min(wallElapsed, upElapsed))
            }
            var icon = iconCache[bundleID]
            if icon == nil, let appIcon = app.icon {
                iconCache[bundleID] = appIcon
                icon = appIcon
            }

            return RunningAppInfo(
                pid: pid,
                bundleIdentifier: bundleID,
                localizedName: name,
                icon: icon,
                isHidden: app.isHidden,
                isProtectedMostRecent: keepPreviousAppVisible && (pid == mostRecentBackgroundPID),
                hasActivePowerAssertion: protectActiveMediaApps && assertionPIDs.contains(pid),
                deactivatedSince: deactivated,
                elapsedInactiveSeconds: elapsed
            )
        }
        .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        self.runningRegularApps = apps
    }

    // MARK: - Launch at Login (SMAppService)

    public func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
                appendLog(.info, "Enabled Launch at Login.", technical: "SMAppService.mainApp.register()")
            } else {
                try SMAppService.mainApp.unregister()
                appendLog(.info, "Disabled Launch at Login.", technical: "SMAppService.mainApp.unregister()")
            }
            refreshLaunchAtLoginStatus()
        } catch {
            launchAtLoginError = error.localizedDescription
            appendLog(.warning, "Couldn't change Launch at Login setting.", technical: "SMAppService error: \(error.localizedDescription)")
            refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - Accessibility (AXUIElement) Helper

    @discardableResult
    public nonisolated func checkAccessibilityPermissions(promptIfNeeded: Bool = false) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: promptIfNeeded as CFBoolean] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func refreshAccessibilityTrustStatus(promptIfNeeded: Bool = false) {
        let trusted = checkAccessibilityPermissions(promptIfNeeded: promptIfNeeded)
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
            appendLog(
                .info,
                trusted ? "Accessibility permission enabled — ready to hide apps." : "Accessibility permission is turned off.",
                technical: "AXIsProcessTrusted=\(trusted)"
            )
        } else {
            isAccessibilityTrusted = trusted
        }

        if promptIfNeeded && !trusted {
            openSystemAccessibilityPrivacyPane()
        }
        startAccessibilityTrustPollingIfNeeded()
    }

    /// Resets any stale macOS TCC Accessibility entry for this bundle ID (e.g., from an older build)
    /// and immediately triggers a fresh permission prompt + opens System Settings.
    public func resetAndPromptAccessibilityPermission() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.systems.autohideagent"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        try? process.run()
        process.waitUntilExit()

        appendLog(
            .info,
            "Refreshed macOS Accessibility permission registration — toggle AutoHideAgent ON in System Settings.",
            technical: "tccutil reset Accessibility \(bundleID)"
        )
        refreshAccessibilityTrustStatus(promptIfNeeded: true)
    }

    public func openSystemAccessibilityPrivacyPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startAccessibilityTrustPollingIfNeeded() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        guard !isAccessibilityTrusted else { return }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = self.checkAccessibilityPermissions(promptIfNeeded: false)
                if trusted != self.isAccessibilityTrusted {
                    self.isAccessibilityTrusted = trusted
                    self.appendLog(
                        .info,
                        trusted ? "Accessibility permission detected — ready to hide apps." : "Accessibility permission turned off.",
                        technical: "live poll AXIsProcessTrusted=\(trusted)"
                    )
                    if trusted {
                        self.accessibilityPollTimer?.invalidate()
                        self.accessibilityPollTimer = nil
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPollTimer = timer
    }

    private enum AXHideOutcome {
        case hidden
        case notTrusted
        case failed(AXError)
    }

    private func hideViaAccessibilityIfTrusted(pid: pid_t) -> AXHideOutcome {
        let trusted = checkAccessibilityPermissions(promptIfNeeded: false)
        isAccessibilityTrusted = trusted
        guard trusted else {
            return .notTrusted
        }
        let axApp = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(axApp, kAXHiddenAttribute as CFString, kCFBooleanTrue)
        return (result == .success) ? .hidden : .failed(result)
    }
}
