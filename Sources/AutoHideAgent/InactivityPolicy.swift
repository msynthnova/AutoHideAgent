import Foundation

/// Pure decision logic; system queries, confirmation UI, and app actions stay in
/// the coordinator. A cached UI snapshot is never used to authorize an action.
enum InactivityPolicy {
    enum Decision: Equatable { case none, hide, quit }
    struct Settings {
        var hideEnabled: Bool
        var quitEnabled: Bool
        var hideThreshold: TimeInterval
        var quitThreshold: TimeInterval
        var keepPreviousVisible: Bool
    }
    struct Context {
        var inactiveSeconds: TimeInterval
        var idleSeconds: TimeInterval
        var isHidden: Bool
        var isPreviousApp: Bool
        var isMediaProtected: Bool
        var quitAlreadyAttempted: Bool
        var quitConfirmationPending: Bool
    }

    static func decide(settings: Settings, app: Context) -> Decision {
        guard !app.isMediaProtected else { return .none }
        if settings.quitEnabled, app.idleSeconds < settings.quitThreshold,
           app.inactiveSeconds >= settings.quitThreshold,
           !app.quitAlreadyAttempted, !app.quitConfirmationPending { return .quit }
        if settings.hideEnabled, !app.isHidden,
           !(settings.keepPreviousVisible && app.isPreviousApp),
           app.idleSeconds < settings.hideThreshold,
           app.inactiveSeconds >= settings.hideThreshold { return .hide }
        return .none
    }
}
