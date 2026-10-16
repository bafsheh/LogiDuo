import Foundation

/// A clock that only moves when a test calls ``advance(by:)``.
///
/// Sleepers are keyed by deadline, so a sleep registered after time has
/// already passed its deadline returns immediately; tests never race the
/// order in which tasks start sleeping.
public final class ManualClock: Clock, @unchecked Sendable {  // Invariant: all mutable state is guarded by `lock`.
    /// A point in manual time.
    public struct Instant: InstantProtocol {
        /// Time since the clock was created.
        public let offset: Duration

        /// Moves the instant by `duration`.
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }

        /// The duration from this instant to `other`.
        public func duration(to other: Instant) -> Duration { other.offset - offset }

        /// Orders instants.
        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UInt64: Sleeper] = [:]
    private var cancelled: Set<UInt64> = []
    private var nextID: UInt64 = 0

    /// Creates a clock at offset zero.
    public init() {}

    /// The current manual time.
    public var now: Instant { lock.withLock { current } }

    /// Manual time has no resolution limit.
    public var minimumResolution: Duration { .zero }

    /// The number of tasks currently sleeping.
    public var sleeperCount: Int { lock.withLock { sleepers.count } }

    /// Suspends until the clock is advanced to `deadline`.
    /// - Throws: `CancellationError` if the task is cancelled first.
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: (any Error)?? = lock.withLock {
                    if cancelled.remove(id) != nil { return .some(CancellationError()) }
                    if deadline <= current { return .some(nil) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .none
                }
                switch resumeNow {
                case .some(.some(let error)): continuation.resume(throwing: error)
                case .some(.none): continuation.resume()
                case .none: break
                }
            }
        } onCancel: {
            let sleeper = lock.withLock {
                guard let sleeper = sleepers.removeValue(forKey: id) else {
                    cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    public func advance(by duration: Duration) {
        let due = lock.withLock {
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers[id] = nil }
            return ready.values.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
