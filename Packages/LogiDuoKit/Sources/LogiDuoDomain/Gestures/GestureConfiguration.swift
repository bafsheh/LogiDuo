/// Tuning of the swipe recognizer. Values are clamped exactly as Mouser does.
public struct GestureConfiguration: Hashable, Sendable {
    /// The engine default: 25 px threshold, 400 ms commit window, 90 ms settle, cross ratio 0.5.
    public static let standard = GestureConfiguration(threshold: 25, commitWindow: .milliseconds(400))

    /// Travel along the dominant axis needed to fire, in device units (at least 8).
    public let commitDistance: Double
    /// Time within which a stroke must reach ``commitDistance`` (at least 50 ms).
    public let commitWindow: Duration
    /// A gap between samples longer than this ends the current stroke (at least 20 ms).
    public let settle: Duration
    /// Permitted off-axis travel relative to on-axis travel (0.05...2.0).
    public let crossRatio: Double
    /// Minimum stroke length before it is tracked.
    public let directionEpsilon: Double
    /// Return travel that re-arms a locked direction for another flick.
    public let minimumReturn: Double

    /// Creates a configuration, clamping every value to its permitted range.
    public init(
        threshold: Double,
        commitWindow: Duration = .milliseconds(400),
        settle: Duration = .milliseconds(90),
        crossRatio: Double = 0.5
    ) {
        commitDistance = max(8, threshold)
        self.commitWindow = max(.milliseconds(50), commitWindow)
        self.settle = max(.milliseconds(20), settle)
        self.crossRatio = min(2, max(0.05, crossRatio))
        directionEpsilon = max(5, commitDistance * 0.15)
        minimumReturn = max(14, commitDistance * 0.45)
    }
}

/// Where movement samples come from while a button is held.
public enum MotionSource: Hashable, Sendable {
    /// Raw XY deltas reported by the device over HID++. Preferred: supersedes event-tap motion.
    case deviceRawXY
    /// Cursor movement observed through the event tap.
    case eventTap
}

/// How a hold ended.
public enum GestureOutcome: Hashable, Sendable {
    /// Released without any swipe: the button's tap (click) action applies.
    case tap
    /// At least one swipe fired during the hold; no tap action applies.
    case swiped([SwipeDirection])
    /// The hold was cancelled or never began; nothing applies.
    case none
}
