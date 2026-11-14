import Foundation

@MainActor
final class EvaluationScheduler {
    enum Mode: Equatable { case stopped, periodic, resumeAt(Date) }
    private(set) var mode: Mode = .stopped
    private var timer: Timer?
    private let interval: TimeInterval
    private let tolerance: TimeInterval

    init(interval: TimeInterval = 15, tolerance: TimeInterval = 5) {
        self.interval = interval
        self.tolerance = tolerance
    }

    static func desiredMode(enabled: Bool, hasFeatures: Bool, pauseUntil: Date?, sessionPaused: Bool) -> Mode {
        guard enabled, !sessionPaused else { return .stopped }
        if let pauseUntil { return .resumeAt(pauseUntil) }
        return hasFeatures ? .periodic : .stopped
    }

    func configure(_ newMode: Mode, evaluate: @escaping @MainActor () -> Void) {
        guard mode != newMode else { return }
        stop()
        mode = newMode
        let delay: TimeInterval
        let repeats: Bool
        switch newMode {
        case .stopped: return
        case .periodic: delay = interval; repeats = true
        case .resumeAt(let date): delay = max(0.001, date.timeIntervalSinceNow); repeats = false
        }
        let timer = Timer(timeInterval: delay, repeats: repeats) { _ in
            MainActor.assumeIsolated { evaluate() }
        }
        timer.tolerance = repeats ? tolerance : min(0.1, delay * 0.01)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        mode = .stopped
    }

    isolated deinit { timer?.invalidate() }
}
