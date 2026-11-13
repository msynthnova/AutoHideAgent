import Foundation

/// Bundle identity, rather than its filesystem location, determines the environment.
enum AppRuntime {
    static var isDevelopment: Bool {
        isDevelopment(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func isDevelopment(bundleIdentifier: String?) -> Bool {
        if let bundleIdentifier {
            return bundleIdentifier == "com.systems.autohideagent.dev"
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
