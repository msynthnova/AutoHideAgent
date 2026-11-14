import Foundation

/// Coalesces lifecycle event bursts without delaying timestamp/safety updates.
@MainActor
final class RefreshCoordinator {
    private var pending: DispatchWorkItem?
    private var action: (@MainActor () -> Void)?
    let delay: TimeInterval

    init(delay: TimeInterval = 0.05) { self.delay = delay }

    func request(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        action = nil
    }

    func flush() {
        let action = action
        cancel()
        action?()
    }

    isolated deinit { pending?.cancel() }
}
