import AppKit
import Foundation

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

public enum PausePreset: Int, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400
    case eightHours = 28800
    case twelveHours = 43200

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .thirtyMinutes: return "30m"
        case .oneHour: return "1h"
        case .twoHours: return "2h"
        case .fourHours: return "4h"
        case .eightHours: return "8h"
        case .twelveHours: return "12h"
        }
    }

    public var shortLabel: String {
        label
    }

    public var descriptiveLabel: String {
        switch self {
        case .thirtyMinutes: return "30 Minutes"
        case .oneHour: return "1 Hour"
        case .twoHours: return "2 Hours"
        case .fourHours: return "4 Hours"
        case .eightHours: return "8 Hours"
        case .twelveHours: return "12 Hours"
        }
    }

    public var fullName: String {
        descriptiveLabel
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
    public let isWhitelisted: Bool
    public let deactivatedSince: Date?
    public let elapsedInactiveSeconds: TimeInterval?

    public var id: String { "\(bundleIdentifier)-\(pid)" }
}

