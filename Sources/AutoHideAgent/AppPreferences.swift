import Foundation

/// Validates persisted settings in one place; the manager publishes UI state.
struct AppPreferences {
    enum Keys {
        static let isEnabled = "com.systems.autohideagent.isEnabled"
        static let isAutoHideEnabled = "com.systems.autohideagent.isAutoHideEnabled"
        static let timeoutSeconds = "com.systems.autohideagent.timeoutSeconds"
        static let isAutoQuitEnabled = "com.systems.autohideagent.isAutoQuitEnabled"
        static let quitTimeoutSeconds = "com.systems.autohideagent.quitTimeoutSeconds"
        static let confirmBeforeAutoQuit = "com.systems.autohideagent.confirmBeforeAutoQuit"
        static let alertOnAppHide = "com.systems.autohideagent.alertOnAppHide"
        static let alertOnAppQuit = "com.systems.autohideagent.alertOnAppQuit"
        static let pauseDurationSeconds = "com.systems.autohideagent.pauseDurationSeconds"
        static let keepPreviousAppVisible = "com.systems.autohideagent.keepPreviousAppVisible"
        static let protectActiveMediaApps = "com.systems.autohideagent.protectActiveMediaApps"
        static let showInDock = "com.systems.autohideagent.showInDock"
        static let showInMenuBar = "com.systems.autohideagent.showInMenuBar"
        static let whitelistedItems = "com.systems.autohideagent.whitelistedItems"
    }

    let isEnabled: Bool
    let isAutoHideEnabled: Bool
    let timeoutSeconds: Int
    let isAutoQuitEnabled: Bool
    let quitTimeoutSeconds: Int
    let confirmBeforeAutoQuit: Bool
    let alertOnAppHide: Bool
    let alertOnAppQuit: Bool
    let pauseDurationSeconds: Int
    let keepPreviousAppVisible: Bool
    let protectActiveMediaApps: Bool
    let showInDock: Bool
    let showInMenuBar: Bool
    let whitelistedBundleIDs: [String]

    init(defaults: UserDefaults) {
        defaults.register(defaults: [
            Keys.isEnabled: true,
            Keys.isAutoHideEnabled: true,
            Keys.timeoutSeconds: TimeoutPreset.fifteenMinutes.rawValue,
            Keys.isAutoQuitEnabled: false,
            Keys.quitTimeoutSeconds: QuitTimeoutPreset.twoHours.rawValue,
            Keys.confirmBeforeAutoQuit: true,
            Keys.alertOnAppHide: false,
            Keys.alertOnAppQuit: true,
            Keys.pauseDurationSeconds: PausePreset.oneHour.rawValue,
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
        self.alertOnAppHide = defaults.bool(forKey: Keys.alertOnAppHide)
        self.alertOnAppQuit = defaults.bool(forKey: Keys.alertOnAppQuit)
        let savedPauseSeconds = defaults.integer(forKey: Keys.pauseDurationSeconds)
        self.pauseDurationSeconds = PausePreset(rawValue: savedPauseSeconds)?.rawValue ?? PausePreset.oneHour.rawValue
        self.keepPreviousAppVisible = defaults.bool(forKey: Keys.keepPreviousAppVisible)
        self.protectActiveMediaApps = defaults.bool(forKey: Keys.protectActiveMediaApps)
        self.showInDock = defaults.bool(forKey: Keys.showInDock)
        self.showInMenuBar = defaults.bool(forKey: Keys.showInMenuBar)
        self.whitelistedBundleIDs = defaults.stringArray(forKey: Keys.whitelistedItems) ?? ["com.apple.finder"]

    }
}
