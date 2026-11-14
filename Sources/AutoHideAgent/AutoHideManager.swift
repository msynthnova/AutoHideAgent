import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import os.log
import ServiceManagement
import UserNotifications

private let logger = Logger(subsystem: "com.systems.autohideagent", category: "AutoHideManager")

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

    private typealias Keys = AppPreferences.Keys

    // MARK: - Persistent Properties

    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.isEnabled)
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
            defaults.set(isAutoHideEnabled, forKey: Keys.isAutoHideEnabled)
            startEvaluationTimer()
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
            defaults.set(timeoutSeconds, forKey: Keys.timeoutSeconds)
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
            defaults.set(isAutoQuitEnabled, forKey: Keys.isAutoQuitEnabled)
            startEvaluationTimer()
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
            defaults.set(quitTimeoutSeconds, forKey: Keys.quitTimeoutSeconds)
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
            defaults.set(confirmBeforeAutoQuit, forKey: Keys.confirmBeforeAutoQuit)
            appendLog(
                .info,
                confirmBeforeAutoQuit ? "Enabled confirmation before quitting apps." : "Disabled confirmation before quitting apps.",
                technical: "confirmBeforeAutoQuit=\(confirmBeforeAutoQuit)"
            )
        }
    }

    /// Feature toggle: Alert with a macOS notification when an app is automatically hidden.
    public var alertOnAppHide: Bool {
        didSet {
            guard alertOnAppHide != oldValue else { return }
            defaults.set(alertOnAppHide, forKey: Keys.alertOnAppHide)
            if alertOnAppHide {
                requestNotificationPermissionIfNeeded()
            }
            appendLog(
                .info,
                alertOnAppHide ? "Enabled notifications when apps are hidden." : "Disabled notifications when apps are hidden.",
                technical: "alertOnAppHide=\(alertOnAppHide)"
            )
            onStateChange?()
        }
    }

    /// Feature toggle: Alert with a macOS notification when an app is automatically quit.
    public var alertOnAppQuit: Bool {
        didSet {
            guard alertOnAppQuit != oldValue else { return }
            defaults.set(alertOnAppQuit, forKey: Keys.alertOnAppQuit)
            if alertOnAppQuit {
                requestNotificationPermissionIfNeeded()
            }
            appendLog(
                .info,
                alertOnAppQuit ? "Enabled notifications when apps are quit." : "Disabled notifications when apps are quit.",
                technical: "alertOnAppQuit=\(alertOnAppQuit)"
            )
            onStateChange?()
        }
    }

    /// Default duration in seconds used when pausing inactivity timers.
    public var pauseDurationSeconds: Int {
        didSet {
            guard pauseDurationSeconds != oldValue else { return }
            defaults.set(pauseDurationSeconds, forKey: Keys.pauseDurationSeconds)
            let label = PausePreset(rawValue: pauseDurationSeconds)?.label ?? "\(pauseDurationSeconds / 60)m"
            appendLog(
                .info,
                "Changed default pause duration to \(label).",
                technical: "pauseDurationSeconds=\(pauseDurationSeconds)"
            )
        }
    }

    public var currentPausePreset: PausePreset {
        PausePreset(rawValue: pauseDurationSeconds) ?? .oneHour
    }

    /// Keeps the single most-recently deactivated background app visible (great when switching between two apps).
    public var keepPreviousAppVisible: Bool {
        didSet {
            guard keepPreviousAppVisible != oldValue else { return }
            defaults.set(keepPreviousAppVisible, forKey: Keys.keepPreviousAppVisible)
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
            defaults.set(protectActiveMediaApps, forKey: Keys.protectActiveMediaApps)
            appMonitor.invalidateAssertions()
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
            defaults.set(showInDock, forKey: Keys.showInDock)
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
            defaults.set(showInMenuBar, forKey: Keys.showInMenuBar)
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
            guard whitelistedBundleIDs != oldValue else { return }
            exclusionIndex.replace(with: whitelistedBundleIDs)
            defaults.set(whitelistedBundleIDs, forKey: Keys.whitelistedItems)
        }
    }

    // MARK: - Runtime State

    /// Tracks the exact timestamp each running `.regular` application transitioned to the background.
    public private(set) var lastDeactivatedDates: [pid_t: Date] = [:]

    /// Tracks PIDs for which we already issued a graceful `terminate()` in the current background session.
    private var autoQuitAttemptedPIDs: Set<pid_t> = []

    /// Tracks PIDs currently showing a confirmation dialog so we don't stack alerts.
    private var pendingQuitConfirmationPIDs: Set<pid_t> = []
    private var pendingQuitNotifications: [pid_t: (name: String, duration: String)] = [:]

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

    @ObservationIgnored var runtimeMetrics = RuntimeMetrics()

    private let defaults: UserDefaults
    private let monitoringEnabled: Bool
    private let dryRunOverride: Bool
    private let evaluationScheduler = EvaluationScheduler()
    private let refreshCoordinator = RefreshCoordinator()
    private let appMonitor = AppMonitor()
    private let logWriter: DiagnosticLogWriter
    @ObservationIgnored private var exclusionIndex = ExclusionIndex([])
    private var accessibilityPollTimer: Timer?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []


    // MARK: - Initialization

    public init(defaults: UserDefaults = .standard, monitoringEnabled: Bool = true, dryRun: Bool = false, logDirectory: URL? = nil) {
        self.defaults = defaults
        self.monitoringEnabled = monitoringEnabled
        self.dryRunOverride = dryRun
        let benchmarkDirectory = AppRuntime.isDevelopment && (dryRun || CommandLine.arguments.contains("--dry-run"))
            ? ProcessInfo.processInfo.environment["AUTOHIDE_BENCHMARK_DIRECTORY"] : nil
        logWriter = DiagnosticLogWriter(url: logDirectory?.appendingPathComponent("AutoHideAgent.log")
            ?? DiagnosticLogWriter.defaultURL(isDevelopment: AppRuntime.isDevelopment, benchmarkDirectory: benchmarkDirectory))
        let settings = AppPreferences(defaults: defaults)
        self.isEnabled = settings.isEnabled
        self.isAutoHideEnabled = settings.isAutoHideEnabled
        self.timeoutSeconds = settings.timeoutSeconds
        self.isAutoQuitEnabled = settings.isAutoQuitEnabled
        self.quitTimeoutSeconds = settings.quitTimeoutSeconds
        self.confirmBeforeAutoQuit = settings.confirmBeforeAutoQuit
        self.alertOnAppHide = settings.alertOnAppHide
        self.alertOnAppQuit = settings.alertOnAppQuit
        self.pauseDurationSeconds = settings.pauseDurationSeconds
        self.keepPreviousAppVisible = settings.keepPreviousAppVisible
        self.protectActiveMediaApps = settings.protectActiveMediaApps
        self.showInDock = settings.showInDock
        self.showInMenuBar = settings.showInMenuBar
        self.whitelistedBundleIDs = settings.whitelistedBundleIDs
        exclusionIndex = ExclusionIndex(settings.whitelistedBundleIDs)

        seedInitialBackgroundTimestamps()
        if monitoringEnabled {
            setupWorkspaceNotifications()
            setupScreenLockAndScreensaverNotifications()
        }
        refreshRunningApps()
        refreshLaunchAtLoginStatus()
        refreshAccessibilityTrustStatus(promptIfNeeded: false)
        startAccessibilityTrustPollingIfNeeded()
        if isDryRunMode {
            appendLog(
                .info,
                "Safe / Dry-Run Mode is ACTIVE. Inactivity evaluations will log actions without hiding or quitting apps.",
                technical: "isDryRunMode=true"
            )
        }
        appendLog(
            .info,
            "\(isDevBuild ? "AutoHideAgent Dev" : "AutoHideAgent") is running and watching background apps.",
            technical: "init() completed; dev=\(isDevBuild), dryRun=\(isDryRunMode), AX=\(isAccessibilityTrusted), autoHide=\(isAutoHideEnabled) (\(timeoutSeconds)s), autoQuit=\(isAutoQuitEnabled) (\(quitTimeoutSeconds)s), confirmQuit=\(confirmBeforeAutoQuit), keepPrev=\(keepPreviousAppVisible), protectMedia=\(protectActiveMediaApps)"
        )
        handleEnabledStateChange()
    }

    // MARK: - Temporary Snooze & Pause

    public var isTemporarilyPaused: Bool {
        guard let until = pausedUntilDate else { return false }
        return Date.now < until
    }

    /// Pauses all inactivity timers for a specified duration in seconds.
    public func pause(for seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0, seconds <= 43200 else {
            appendLog(.warning, "Invalid pause duration. Choose a duration up to 12 hours.")
            return
        }
        let until = Date.now.addingTimeInterval(seconds)
        pausedUntilDate = until
        startEvaluationTimer()
        let friendly = formatFriendlyDuration(seconds)
        appendLog(
            .info,
            "Paused AutoHideAgent for \(friendly).",
            technical: "pausedUntil=\(Self.isoFormatter.string(from: until)), seconds=\(Int(seconds))"
        )
        onStateChange?()
    }

    /// Toggles pausing: if paused, resumes; otherwise pauses for the requested duration or current default duration.
    public func togglePause(for seconds: TimeInterval? = nil) {
        if isTemporarilyPaused {
            resumeFromTemporaryPause()
        } else {
            let duration = seconds ?? TimeInterval(pauseDurationSeconds)
            pause(for: duration)
        }
    }

    public func togglePauseForOneHour() {
        togglePause(for: 3600)
    }

    public func resumeFromTemporaryPause() {
        guard pausedUntilDate != nil else { return }
        pausedUntilDate = nil
        startEvaluationTimer()
        // Reset background timestamps to now so apps aren't immediately hidden on unpause
        seedInitialBackgroundTimestamps()
        appendLog(.info, "Resumed AutoHideAgent from temporary pause.", technical: "manual/auto resume")
        onStateChange?()
        refreshRunningApps()
    }

    // MARK: - User Notifications & Alerts

    private var canUseNotifications: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    public func requestNotificationPermissionIfNeeded() {
        guard canUseNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                if let error = error {
                    self?.appendLog(.warning, "Notification permission request error.", technical: "error=\(error.localizedDescription)")
                } else if granted {
                    self?.appendLog(.info, "Notification permission granted.", technical: "granted=true")
                }
            }
        }
    }

    public func postUserNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        guard canUseNotifications else {
            appendLog(.info, "[Alert Notification] \(title): \(body)", technical: "canUseNotifications=false (running unbundled)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                Task { @MainActor [weak self] in
                    self?.appendLog(.warning, "Failed to deliver notification: \(title)", technical: "error=\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Safe / Dry-Run Mode & Environment Isolation

    /// Identifies whether the current process is running as a local development/debug build.
    public var isDevBuild: Bool {
        AppRuntime.isDevelopment
    }

    /// When true, inactivity evaluations and hide/quit actions will only log what they WOULD do,
    /// ensuring local testing never disrupts active user apps.
    /// Activated via `--dry-run` CLI argument, or `AUTOHIDE_DRY_RUN=1` / `AUTOHIDE_SAFE_MODE=1` environment variable.
    public var isDryRunMode: Bool {
        dryRunOverride || CommandLine.arguments.contains("--dry-run") ||
        ProcessInfo.processInfo.environment["AUTOHIDE_DRY_RUN"] == "1" ||
        ProcessInfo.processInfo.environment["AUTOHIDE_SAFE_MODE"] == "1"
    }

    // MARK: - Instant "Hide Background Apps Now" Action

    /// Number of currently visible (unhidden) background `.regular` applications.
    public var visibleBackgroundAppsCount: Int {
        runningRegularApps.filter { !$0.isHidden }.count
    }

    /// Number of currently hidden background `.regular` applications.
    public var hiddenBackgroundAppsCount: Int {
        runningRegularApps.filter { $0.isHidden }.count
    }

    /// Number of visible background applications that are eligible to be hidden (not whitelisted).
    public var eligibleToHideCount: Int {
        runningRegularApps.filter { !$0.isHidden && !$0.isWhitelisted }.count
    }

    /// Immediately hides all currently visible, non-whitelisted background `.regular` applications.
    public func hideAllBackgroundAppsNow() {
        if isDryRunMode {
            let count = eligibleToHideCount
            appendLog(
                .info,
                "[DRY RUN] Would hide \(count) background \(count == 1 ? "app" : "apps") now.",
                technical: "dryRun=true, eligible=\(count)"
            )
            return
        }

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
        if isDryRunMode {
            appendLog(
                .info,
                "[DRY RUN] Would manually hide \(appInfo.localizedName).",
                technical: "dryRun=true, pid=\(appInfo.pid), bundleID=\(appInfo.bundleIdentifier)"
            )
            return
        }
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
        if isDryRunMode {
            appendLog(.info, "[DRY RUN] Would manually quit \(appInfo.localizedName).", technical: "dryRun=true, pid=\(appInfo.pid)")
            return
        }
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
                "Requested quit for \(appInfo.localizedName).",
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

    /// Path to the persistent diagnostic log file (`~/Library/Logs/AutoHideAgent/AutoHideAgent.log` or `AutoHideAgent-Dev`).
    public var logFileURL: URL { logWriter.url }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Formats a duration in seconds into a friendly string for everyday users (e.g., "15 mins", "2 hrs").
    public nonisolated func formatFriendlyDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0 sec" }
        let totalSeconds = Int(min(Double(Int.max / 2), max(0, round(seconds))))
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
        runtimeMetrics.logEntries += 1
        logWriter.append(line)
    }

    public func flushDiagnosticLog() async { try? await logWriter.flush() }

    public func finishDiagnosticLog() { logWriter.finish() }

    public func openDiagnosticLogFile() {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            appendLog(.info, "Created diagnostic log file.", technical: "path=\(url.path)")
        }
        let snapshot = "[\(Self.isoFormatter.string(from: Date.now))] [SNAPSHOT] Enabled=\(isEnabled), PausedUntil=\(String(describing: pausedUntilDate)), HideTimeout=\(timeoutSeconds)s, AutoQuit=\(isAutoQuitEnabled) (\(quitTimeoutSeconds)s), ConfirmQuit=\(confirmBeforeAutoQuit), KeepPrev=\(keepPreviousAppVisible), ProtectMedia=\(protectActiveMediaApps), AXTrusted=\(isAccessibilityTrusted), HIDIdle=\(String(format: "%.1f", currentHIDIdleSeconds()))s, ActivePauseReasons=\(activePauseReasons), TrackedApps=\(lastDeactivatedDates.count), Whitelist=\(whitelistedBundleIDs)\n"
        writeToPersistentLogFile(snapshot)
        Task { @MainActor [logWriter] in
            try? await logWriter.flush()
            NSWorkspace.shared.open(url)
        }
    }

    public func revealDiagnosticLogInFinder() {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            appendLog(.info, "Created diagnostic log file.", technical: "path=\(url.path)")
        }
        Task { @MainActor [logWriter] in
            try? await logWriter.flush()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
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
                    self.pendingQuitNotifications.removeValue(forKey: pid)
                    if self.mostRecentBackgroundPID == pid {
                        self.recomputeMostRecentBackgroundPID()
                    }
                }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                }
                self.requestRunningAppsRefresh()
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
                self.requestRunningAppsRefresh()
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
                    if let quit = self.pendingQuitNotifications.removeValue(forKey: pid) {
                        self.appendLog(.action, "Quit \(quit.name) (unused for \(quit.duration)).", technical: "confirmed termination pid=\(pid)")
                        if self.alertOnAppQuit {
                            self.postUserNotification(title: "App Quit", body: "\(quit.name) was automatically quit (inactive for \(quit.duration)).")
                        }
                    }
                    if self.mostRecentBackgroundPID == pid {
                        self.recomputeMostRecentBackgroundPID()
                    }
                }
                if let bundleID {
                    self.appMonitor.removeIcon(bundleID: bundleID)
                }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityTrustStatus(promptIfNeeded: false)
                }
                self.requestRunningAppsRefresh()
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
                self.requestRunningAppsRefresh()
            }
        }

        // 5. Application hidden/unhidden
        let hideObserver = nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestRunningAppsRefresh()
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
                self.requestRunningAppsRefresh()
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

        applicationObservers = [appActiveObserver]
        workspaceObservers = [
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
    public func activePowerAssertionPIDs() -> Set<pid_t> {
        let result = appMonitor.protectedPIDs(forceFresh: true)
        runtimeMetrics.powerAssertionQueries = appMonitor.assertionQueryCount
        return result
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
        guard monitoringEnabled else { evaluationScheduler.stop(); return }
        let mode = EvaluationScheduler.desiredMode(enabled: isEnabled,
            hasFeatures: isAutoHideEnabled || isAutoQuitEnabled, pauseUntil: pausedUntilDate,
            sessionPaused: !activePauseReasons.isEmpty)
        evaluationScheduler.configure(mode) { [weak self] in self?.evaluateAndHideInactiveApps() }
    }

    private func stopEvaluationTimer() { evaluationScheduler.stop() }

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
        runtimeMetrics.evaluationCallbacks += 1
        guard isEnabled else { return }

        // Expire snoozes even when permission is unavailable or automation is off.
        if let until = pausedUntilDate {
            if Date.now >= until {
                resumeFromTemporaryPause()
            } else {
                return
            }
        }

        guard isAccessibilityTrusted || isDryRunMode else { return }
        guard isAutoHideEnabled || isAutoQuitEnabled else { return }
        guard pendingQuitConfirmationPIDs.isEmpty else { return }

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
        let snapshot = appMonitor.capture(protectMedia: protectActiveMediaApps, forceFresh: true)
        runtimeMetrics.powerAssertionQueries = appMonitor.assertionQueryCount
        let myPID = ProcessInfo.processInfo.processIdentifier
        let settings = InactivityPolicy.Settings(hideEnabled: isAutoHideEnabled, quitEnabled: isAutoQuitEnabled,
            hideThreshold: hideThreshold, quitThreshold: quitThreshold, keepPreviousVisible: keepPreviousAppVisible)

        for app in snapshot.applications {
            let pid = app.processIdentifier

            // 1. Must be a standard user-facing application (.regular)
            guard app.activationPolicy == .regular else { continue }

            // 2. Must not be terminated
            guard app.isTerminated == false else { continue }

            // 3. Must not be the frontmost application (or ourselves)
            guard pid != snapshot.frontmostPID, pid != myPID else {
                lastDeactivatedDates.removeValue(forKey: pid)
                lastDeactivatedUptimes.removeValue(forKey: pid)
                autoQuitAttemptedPIDs.remove(pid)
                continue
            }

            // 4. Never auto-hide or auto-quit Finder
            guard app.bundleIdentifier != "com.apple.finder" else { continue }

            // 5. Must not match the user's whitelist (by bundleIdentifier or localizedName)
            guard !isAppWhitelisted(app) else { continue }

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

            let decision = InactivityPolicy.decide(settings: settings, app: .init(
                inactiveSeconds: inactiveDuration, idleSeconds: idleSeconds, isHidden: app.isHidden,
                isPreviousApp: pid == mostRecentBackgroundPID,
                isMediaProtected: snapshot.protectedPIDs.contains(pid),
                quitAlreadyAttempted: autoQuitAttemptedPIDs.contains(pid),
                quitConfirmationPending: pendingQuitConfirmationPIDs.contains(pid)))

            if decision == .quit {
                let friendlyTime = formatFriendlyDuration(inactiveDuration)
                if confirmBeforeAutoQuit && !isDryRunMode {
                    promptAndConfirmAutoQuit(for: app, appName: appName, friendlyTime: friendlyTime, inactiveDuration: inactiveDuration)
                    // Modal UI can change settings, focus, exclusions, or pause state.
                    // Finish this pass rather than reusing its pre-dialog snapshot.
                    return
                } else {
                    autoQuitAttemptedPIDs.insert(pid)
                    performGracefulQuit(for: app, appName: appName, friendlyTime: friendlyTime, inactiveDuration: inactiveDuration)
                }
                continue
            }

            guard decision == .hide else { continue }

            let friendlyTime = formatFriendlyDuration(inactiveDuration)

            if isDryRunMode {
                appendLog(
                    .info,
                    "[DRY RUN] Would hide \(appName) (unused for \(friendlyTime)).",
                    technical: "dryRun=true, pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s"
                )
                continue
            }

            let didHide = app.hide()
            if didHide {
                appendLog(
                    .action,
                    "Hid \(appName) (unused for \(friendlyTime)).",
                    technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s, method=NSRunningApplication.hide()"
                )
                if alertOnAppHide {
                    postUserNotification(
                        title: "App Hidden",
                        body: "\(appName) was automatically hidden (inactive for \(friendlyTime))."
                    )
                }
            } else {
                let axOutcome = hideViaAccessibilityIfTrusted(pid: pid)
                switch axOutcome {
                case .hidden:
                    appendLog(
                        .action,
                        "Hid \(appName) (unused for \(friendlyTime)).",
                        technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s, method=AXUIElement(kAXHiddenAttribute)"
                    )
                    if alertOnAppHide {
                        postUserNotification(
                            title: "App Hidden",
                            body: "\(appName) was automatically hidden (inactive for \(friendlyTime))."
                        )
                    }
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

        refreshRunningApps(using: snapshot)
    }

    // MARK: - Auto-Quit Confirmation & Execution

    private func performGracefulQuit(
        for app: NSRunningApplication,
        appName: String,
        friendlyTime: String,
        inactiveDuration: TimeInterval
    ) {
        let pid = app.processIdentifier

        if isDryRunMode {
            appendLog(
                .info,
                "[DRY RUN] Would quit \(appName) (unused for \(friendlyTime)).",
                technical: "dryRun=true, pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s"
            )
            return
        }

        pendingQuitNotifications[pid] = (appName, friendlyTime)
        let didTerminate = app.terminate()
        if didTerminate {
            appendLog(
                .action,
                "Requested quit for \(appName) (unused for \(friendlyTime)).",
                technical: "pid=\(pid), bundleID=\(app.bundleIdentifier ?? "nil"), inactive=\(Int(inactiveDuration))s, method=terminate()"
            )
        } else {
            pendingQuitNotifications.removeValue(forKey: pid)
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
        if isDryRunMode {
            performGracefulQuit(for: app, appName: appName, friendlyTime: friendlyTime, inactiveDuration: inactiveDuration)
            return
        }
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
            // Safety guard: Ensure the app did not become active or terminated while the modal dialog was open
            guard isEnabled, isAutoQuitEnabled, !isTemporarilyPaused,
                  activePauseReasons.isEmpty, !isAppWhitelisted(app),
                  Date.now.timeIntervalSince(lastDeactivatedDates[pid] ?? .now) >= TimeInterval(quitTimeoutSeconds),
                  !(protectActiveMediaApps && activePowerAssertionPIDs().contains(pid)),
                  !app.isTerminated, !app.isActive, app != NSWorkspace.shared.frontmostApplication else {
                appendLog(
                    .info,
                    "Cancelled quitting \(appName) because its eligibility changed.",
                    technical: "pid=\(pid), isTerminated=\(app.isTerminated), isActive=\(app.isActive)"
                )
                break
            }
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
        isExcluded(bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName)
    }

    func isExcluded(bundleIdentifier: String?, localizedName: String?) -> Bool {
        exclusionIndex.contains(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
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

    public func requestRunningAppsRefresh() {
        runtimeMetrics.refreshRequests += 1
        refreshCoordinator.request { [weak self] in self?.refreshRunningApps() }
    }

    public func refreshRunningApps() {
        refreshCoordinator.cancel()
        let snapshot = appMonitor.capture(protectMedia: protectActiveMediaApps, forceFresh: false)
        refreshRunningApps(using: snapshot)
    }

    private func refreshRunningApps(using snapshot: AppMonitor.Snapshot) {
        refreshCoordinator.cancel()
        runtimeMetrics.appScans += 1
        runtimeMetrics.powerAssertionQueries = appMonitor.assertionQueryCount
        let frontmostPID = snapshot.frontmostPID
        let myBundleID = Bundle.main.bundleIdentifier
        let now = sleepBeganDate ?? Date.now
        let currentUptime = ProcessInfo.processInfo.systemUptime
        let assertionPIDs = snapshot.protectedPIDs

        let apps: [RunningAppInfo] = snapshot.applications.compactMap { app in
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
            let icon = appMonitor.icon(for: app, bundleID: bundleID)

            let whitelisted = isAppWhitelisted(app)

            return RunningAppInfo(
                pid: pid,
                bundleIdentifier: bundleID,
                localizedName: name,
                icon: icon,
                isHidden: app.isHidden,
                isProtectedMostRecent: keepPreviousAppVisible && (pid == mostRecentBackgroundPID),
                hasActivePowerAssertion: protectActiveMediaApps && assertionPIDs.contains(pid),
                isWhitelisted: whitelisted,
                deactivatedSince: deactivated,
                elapsedInactiveSeconds: elapsed
            )
        }
        .sorted { (a, b) -> Bool in
            // 1. Visible (open) applications appear before hidden applications
            if a.isHidden != b.isHidden {
                return !a.isHidden && b.isHidden
            }
            // 2. Protected most-recent background app comes first among visible apps
            if a.isProtectedMostRecent != b.isProtectedMostRecent {
                return a.isProtectedMostRecent && !b.isProtectedMostRecent
            }
            // 3. For apps with known inactivity, most recently active comes first
            let aElapsed = a.elapsedInactiveSeconds ?? 0
            let bElapsed = b.elapsedInactiveSeconds ?? 0
            if abs(aElapsed - bElapsed) > 1.0 {
                return aElapsed < bElapsed
            }
            // 4. Alphabetical tie-breaker
            return a.localizedName.localizedCaseInsensitiveCompare(b.localizedName) == .orderedAscending
        }

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
        guard monitoringEnabled else { return }
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

    isolated deinit {
        stopEvaluationTimer()
        refreshCoordinator.cancel()
        logWriter.finish()
        accessibilityPollTimer?.invalidate()
        for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            nc.removeObserver(observer)
        }
        let dnc = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            dnc.removeObserver(observer)
        }
    }
}
