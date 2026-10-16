public import LogiDuoDomain

/// Exponential backoff between reconnection attempts.
public struct BackoffPolicy: Hashable, Sendable {
    /// Mouser's schedule: 1.5 s, doubling, capped at 30 s; 0.5 s after wake.
    public static let standard = BackoffPolicy(
        initial: .milliseconds(1500),
        maximum: .seconds(30),
        afterWake: .milliseconds(500)
    )

    /// Delay before the first retry.
    public let initial: Duration
    /// Upper bound for any delay.
    public let maximum: Duration
    /// Delay before reconnecting after the Mac wakes.
    public let afterWake: Duration

    /// Creates a policy.
    public init(initial: Duration, maximum: Duration, afterWake: Duration) {
        self.initial = initial
        self.maximum = max(initial, maximum)
        self.afterWake = afterWake
    }

    /// The delay before the next attempt after `failures` consecutive failures.
    public func delay(afterFailures failures: Int) -> Duration {
        var delay = initial
        for _ in 1..<max(failures, 1) where delay < maximum {
            delay *= 2
        }
        return min(delay, maximum)
    }
}

/// Tunables for one ``HIDPPConnection``.
public struct HIDPPConnectionConfiguration: Sendable {
    /// Default timeout for requests.
    public var requestTimeout: Duration = .seconds(2)
    /// Timeout for each handshake request while connecting.
    public var handshakeTimeout: Duration = .milliseconds(400)
    /// Extra attempts for read requests that fail transiently. Writes are never retried.
    public var readRetryLimit = 1
    /// Consecutive request timeouts after which the device is treated as unresponsive.
    public var unresponsiveThreshold = 3
    /// Delays between reconnection attempts.
    public var backoff: BackoffPolicy = .standard
    /// How many consecutive failed connection attempts are tolerated.
    public var retryPolicy: RetryPolicy

    /// Creates a configuration with default values and `retryPolicy`.
    public init(retryPolicy: RetryPolicy) {
        self.retryPolicy = retryPolicy
    }
}
