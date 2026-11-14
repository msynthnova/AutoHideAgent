import AppKit
import Foundation

struct RuntimeMetrics: Codable, Sendable {
    var refreshRequests = 0
    var appScans = 0
    var powerAssertionQueries = 0
    var logEntries = 0
    var evaluationCallbacks = 0
}

/// Opt-in instrumentation, restricted to a development bundle in dry-run mode.
@MainActor
enum PerformanceHooks {
    struct Command: Decodable, Sendable {
        let action: String
        let output: String
        var iterations: Int?
    }

    static func install(manager: AutoHideManager, present: @escaping @MainActor (String) -> Void) -> NSObjectProtocol? {
        guard manager.isDevBuild, manager.isDryRunMode,
              ProcessInfo.processInfo.environment["AUTOHIDE_BENCHMARK_DIRECTORY"] != nil else { return nil }
        return DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.systems.autohideagent.dev.benchmark"), object: nil, queue: .main
        ) { notification in
            guard let string = notification.object as? String,
                  let data = string.data(using: .utf8),
                  let command = try? JSONDecoder().decode(Command.self, from: data) else { return }
            Task { @MainActor in
                let started = ProcessInfo.processInfo.systemUptime
                let count = min(10_000, max(0, command.iterations ?? 1000))
                switch command.action {
                case "dashboard", "menu", "background", "off", "paused":
                    manager.isEnabled = true
                    manager.resumeFromTemporaryPause()
                    manager.isAutoHideEnabled = command.action != "off"
                    manager.isAutoQuitEnabled = false
                    if command.action == "paused" { manager.pause(for: 3600) }
                    present(command.action)
                case "refreshBurst":
                    for _ in 0..<count { manager.requestRunningAppsRefresh() }
                case "logBurst":
                    for index in 0..<count {
                        manager.appendLog(.info, "Performance test event \(index)", technical: String(repeating: "x", count: 160))
                    }
                default: break
                }
                let mainThreadMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                try? await Task.sleep(for: .milliseconds(150))
                await manager.flushDiagnosticLog()
                let result: [String: Any] = [
                    "metrics": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(manager.runtimeMetrics))) ?? [:],
                    "mainThreadMilliseconds": mainThreadMilliseconds,
                    "completedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000
                ]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: command.output), options: .atomic)
                }
            }
        }
    }
}
