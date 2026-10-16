/// Turns horizontal scroll deltas into discrete actions.
///
/// Port of Mouser's engine rule (`core/engine.py:_make_hscroll_handler`):
/// each event contributes `min(|delta|, 1)` (one step if the size is unknown)
/// towards ``threshold``; reaching it fires and starts a cooldown during which
/// events are dropped and the accumulation is reset. Directions accumulate
/// independently.
public struct HorizontalScrollAccumulator: Hashable, Sendable {
    /// Cooldown after an action fires.
    public static let actionCooldown = Duration.milliseconds(350)
    /// Shorter cooldown for volume actions, so holding the wheel steps the volume smoothly.
    public static let volumeCooldown = Duration.milliseconds(60)
    /// Mouser's default threshold after its configuration migrations.
    public static let defaultThreshold = 0.1

    private struct DirectionState: Hashable {
        var accumulated = 0.0
        var lastFire: Duration?
    }

    /// The accumulated amount needed to fire (at least 0.01).
    public let threshold: Double
    private var states: [HorizontalScrollDirection: DirectionState] = [:]

    /// Creates an accumulator, clamping `threshold` to at least 0.01.
    public init(threshold: Double = defaultThreshold) {
        self.threshold = max(0.01, threshold)
    }

    /// The cooldown that applies after `action` fires.
    public static func cooldown(for action: Action) -> Duration {
        switch action {
        case .media(.volumeUp), .media(.volumeDown): volumeCooldown
        default: actionCooldown
        }
    }

    /// Feeds one scroll event.
    /// - Parameters:
    ///   - direction: Scroll direction.
    ///   - delta: The event's magnitude, or `nil` if unknown (counts as one step).
    ///   - cooldown: The cooldown of the mapped action (see ``cooldown(for:)``).
    ///   - time: Monotonic time of the event.
    /// - Returns: Whether the mapped action fires now.
    public mutating func feed(
        _ direction: HorizontalScrollDirection,
        delta: Double?,
        cooldown: Duration,
        at time: Duration
    ) -> Bool {
        var state = states[direction] ?? DirectionState()
        defer { states[direction] = state }
        if let last = state.lastFire, time - last < cooldown {
            state.accumulated = 0
            return false
        }
        state.accumulated += min(abs(delta ?? 1), 1)
        guard state.accumulated >= threshold else { return false }
        state.accumulated = 0
        state.lastFire = time
        return true
    }
}
