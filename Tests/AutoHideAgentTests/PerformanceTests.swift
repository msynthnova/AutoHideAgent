import AppKit
import Foundation
import Testing
@testable import AutoHideAgent

@Suite("Performance and scheduling regressions")
@MainActor
final class PerformanceTests {
    private let suite = "AutoHideAgent.PerformanceTests.\(UUID().uuidString)"
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private lazy var defaults = UserDefaults(suiteName: suite)!

    private func manager() -> AutoHideManager {
        AutoHideManager(defaults: defaults, monitoringEnabled: false, dryRun: true, logDirectory: directory)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("One thousand refresh requests produce one UI rebuild")
    func refreshBurstCoalesces() async throws {
        let manager = manager()
        let scans = manager.runtimeMetrics.appScans
        let queries = manager.runtimeMetrics.powerAssertionQueries
        for _ in 0..<1000 { manager.requestRunningAppsRefresh() }
        #expect(manager.runtimeMetrics.appScans == scans)
        try await Task.sleep(for: .milliseconds(150))
        #expect(manager.runtimeMetrics.appScans == scans + 1)
        #expect(manager.runtimeMetrics.powerAssertionQueries <= queries + 1)
    }

    @Test("An explicit refresh cancels the pending duplicate")
    func immediateRefreshCancelsPending() async throws {
        let manager = manager()
        let scans = manager.runtimeMetrics.appScans
        manager.requestRunningAppsRefresh()
        manager.refreshRunningApps()
        try await Task.sleep(for: .milliseconds(150))
        #expect(manager.runtimeMetrics.appScans == scans + 1)
    }

    @Test("Display caching never supplies stale assertions to a decision")
    func freshProtectionAssertions() {
        var protected: Set<pid_t> = [1]
        let monitor = AppMonitor(readAssertions: { protected })
        #expect(monitor.protectedPIDs(forceFresh: false) == [1])
        protected = [2]
        #expect(monitor.protectedPIDs(forceFresh: false) == [1])
        #expect(monitor.assertionQueryCount == 1)
        #expect(monitor.protectedPIDs(forceFresh: true) == [2])
        #expect(monitor.assertionQueryCount == 2)
        monitor.invalidateAssertions()
        #expect(monitor.protectedPIDs(forceFresh: false) == [2])
        #expect(monitor.assertionQueryCount == 3)
    }

    @Test("Exclusions are normalized only on edits and cover both names and bundle IDs")
    func exclusionIndexInvalidation() {
        var index = ExclusionIndex(["COM.Example.App", "Music"])
        for _ in 0..<1000 {
            #expect(index.contains(bundleIdentifier: "com.example.app", localizedName: nil))
            #expect(index.contains(bundleIdentifier: nil, localizedName: "MUSIC"))
        }
        #expect(index.rebuildCount == 1)
        index.replace(with: ["Other"])
        #expect(!index.contains(bundleIdentifier: "com.example.app", localizedName: "Music"))
        #expect(index.contains(bundleIdentifier: nil, localizedName: "other"))
        #expect(index.rebuildCount == 2)
    }

    @Test("Direct exclusion edits invalidate the manager cache immediately")
    func managerExclusionInvalidation() {
        let manager = manager()
        manager.whitelistedBundleIDs = ["COM.EXAMPLE.TEST"]
        #expect(manager.isExcluded(bundleIdentifier: "com.example.test", localizedName: nil))
        manager.whitelistedBundleIDs = []
        #expect(!manager.isExcluded(bundleIdentifier: "com.example.test", localizedName: nil))
    }

    @Test("Inactive features stop periodic evaluations but preserve a single pause expiry")
    func evaluationScheduleModes() {
        let deadline = Date.now.addingTimeInterval(3600)
        #expect(EvaluationScheduler.desiredMode(enabled: true, hasFeatures: false, pauseUntil: nil, sessionPaused: false) == .stopped)
        #expect(EvaluationScheduler.desiredMode(enabled: true, hasFeatures: true, pauseUntil: nil, sessionPaused: false) == .periodic)
        #expect(EvaluationScheduler.desiredMode(enabled: true, hasFeatures: false, pauseUntil: deadline, sessionPaused: false) == .resumeAt(deadline))
        #expect(EvaluationScheduler.desiredMode(enabled: false, hasFeatures: true, pauseUntil: deadline, sessionPaused: false) == .stopped)
        #expect(EvaluationScheduler.desiredMode(enabled: true, hasFeatures: true, pauseUntil: deadline, sessionPaused: true) == .stopped)
    }

    @Test("A pause wakeup fires once rather than polling")
    func pauseWakeIsOneShot() async throws {
        let scheduler = EvaluationScheduler(interval: 0.01, tolerance: 0)
        var callbacks = 0
        scheduler.configure(.resumeAt(.now.addingTimeInterval(0.02))) { callbacks += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(callbacks == 1)
        scheduler.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(callbacks == 1)
    }

    @Test("Stopping evaluation cancels future periodic callbacks")
    func periodicStop() async throws {
        let scheduler = EvaluationScheduler(interval: 0.01, tolerance: 0)
        var callbacks = 0
        scheduler.configure(.periodic) { callbacks += 1 }
        try await Task.sleep(for: .milliseconds(70))
        scheduler.stop()
        let stopped = callbacks
        #expect(stopped > 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(callbacks == stopped)
    }

    @Test("Asynchronous diagnostic entries are ordered and flushed completely")
    func asynchronousLogOrder() async throws {
        let url = directory.appendingPathComponent("order.log")
        let writer = DiagnosticLogWriter(url: url)
        for index in 0..<1000 { writer.append("event-\(index)\n") }
        try await writer.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("event-") }
        #expect(lines.count == 1000)
        #expect(lines.first == "event-0")
        #expect(lines.last == "event-999")
        for (index, line) in lines.enumerated() { #expect(line == "event-\(index)") }
        writer.finish()
    }

    @Test("Log rotation retains only current and previous files")
    func boundedLogRotation() async throws {
        let url = directory.appendingPathComponent("rotate.log")
        let writer = DiagnosticLogWriter(url: url, maximumBytes: 500)
        for index in 0..<200 { writer.append("entry-\(index):" + String(repeating: "x", count: 40) + "\n") }
        try await writer.flush()
        let previous = url.deletingPathExtension().appendingPathExtension("old.log")
        let current = try Data(contentsOf: url)
        #expect(current.count <= 500)
        #expect(try Data(contentsOf: previous).count <= 500)
        #expect(String(decoding: current, as: UTF8.self).contains("entry-199:"))
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2)
        writer.finish()
    }

    @Test("Log failures propagate through the flush boundary")
    func logFailureReported() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("file-not-a-directory")
        try Data().write(to: file)
        let writer = DiagnosticLogWriter(url: file.appendingPathComponent("invalid.log"))
        writer.append("test\n")
        await #expect(throws: (any Error).self) { try await writer.flush() }
        writer.finish()
    }

    @Test("Decision policy preserves quit priority, media protection, and previous-app behavior")
    func decisionSafety() {
        var settings = InactivityPolicy.Settings(hideEnabled: true, quitEnabled: true,
            hideThreshold: 300, quitThreshold: 3600, keepPreviousVisible: true)
        var app = InactivityPolicy.Context(inactiveSeconds: 7200, idleSeconds: 0, isHidden: false,
            isPreviousApp: true, isMediaProtected: false, quitAlreadyAttempted: false, quitConfirmationPending: false)
        #expect(InactivityPolicy.decide(settings: settings, app: app) == .quit)
        app.isMediaProtected = true
        #expect(InactivityPolicy.decide(settings: settings, app: app) == .none)
        app.isMediaProtected = false
        settings.quitEnabled = false
        #expect(InactivityPolicy.decide(settings: settings, app: app) == .none)
        app.isPreviousApp = false
        #expect(InactivityPolicy.decide(settings: settings, app: app) == .hide)
        app.isHidden = true
        #expect(InactivityPolicy.decide(settings: settings, app: app) == .none)
        app.isHidden = false
        app.idleSeconds = 400
        #expect(InactivityPolicy.decide(settings: settings, app: app) == .none)
    }
}
