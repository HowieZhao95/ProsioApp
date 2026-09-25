import Foundation
import ProsioCore

/// Races `operation` against a `duration` sleep; throws `onTimeout` if the sleep wins.
/// Cancels the loser so it doesn't keep running after this returns.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    onTimeout: ProsioError,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw onTimeout
        }
        guard let result = try await group.next() else {
            throw ProsioError.cancelled
        }
        group.cancelAll()
        return result
    }
}

/// Signals a single instant (when audio-done was sent) that other tasks can await, then compute a
/// deadline relative to. Suspends `deadline(after:)` callers until `mark()` is called — so a
/// waiter never times out before the marked event actually happens.
actor DeadlineMarker {
    private var markedAt: ContinuousClock.Instant?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Records "now" as the mark instant, exactly once. Resumes anyone already waiting.
    func mark() {
        guard markedAt == nil else { return }
        markedAt = ContinuousClock.now
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    /// Suspends until `mark()` has been called, then returns `markedAt + duration`.
    func deadline(after duration: Duration) async -> ContinuousClock.Instant {
        if let markedAt {
            return markedAt.advanced(by: duration)
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // `mark()` always sets `markedAt` before resuming waiters.
        return (markedAt ?? ContinuousClock.now).advanced(by: duration)
    }
}
