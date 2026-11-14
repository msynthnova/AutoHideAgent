import AppKit
import IOKit.pwr_mgt

/// Captures one consistent system snapshot per evaluation and owns icon/media
/// caches. Decisions always request fresh media assertions; only display refreshes
/// may reuse them for up to one second.
@MainActor
final class AppMonitor {
    struct Snapshot {
        let applications: [NSRunningApplication]
        let frontmostPID: pid_t?
        let protectedPIDs: Set<pid_t>
    }

    private var icons: [String: NSImage] = [:]
    private var assertions: Set<pid_t> = []
    private var assertionTime: TimeInterval = -.infinity
    private let readAssertions: () -> Set<pid_t>
    private(set) var assertionQueryCount = 0

    init(readAssertions: @escaping () -> Set<pid_t> = AppMonitor.queryPowerAssertions) {
        self.readAssertions = readAssertions
    }

    func protectedPIDs(forceFresh: Bool) -> Set<pid_t> {
        let now = ProcessInfo.processInfo.systemUptime
        if forceFresh || now - assertionTime >= 1 {
            assertions = readAssertions()
            assertionTime = now
            assertionQueryCount += 1
        }
        return assertions
    }

    func capture(protectMedia: Bool, forceFresh: Bool) -> Snapshot {
        Snapshot(applications: NSWorkspace.shared.runningApplications,
                 frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                 protectedPIDs: protectMedia ? protectedPIDs(forceFresh: forceFresh) : [])
    }

    func invalidateAssertions() { assertionTime = -.infinity }
    func removeIcon(bundleID: String) { icons.removeValue(forKey: bundleID) }

    func icon(for app: NSRunningApplication, bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        let icon = app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? app.icon
        icon?.size = NSSize(width: 64, height: 64)
        icons[bundleID] = icon
        return icon
    }

    nonisolated static func queryPowerAssertions() -> Set<pid_t> {
        var assertionsByPID: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByPID)
        guard status == kIOReturnSuccess,
              let dict = assertionsByPID?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let protectedTypes: Set<String> = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep",
            "NoDisplaySleepAssertion", "NoIdleSleepAssertion", "audio-out", "audio-in"]
        return Set(dict.compactMap { pid, assertions in
            assertions.contains { assertion in
                (assertion["AssertType"] as? String).map(protectedTypes.contains) ?? false
            } ? pid_t(pid.int32Value) : nil
        })
    }
}
