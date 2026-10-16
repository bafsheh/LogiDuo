/// Turns movement deltas reported while a button is held into swipes.
///
/// A faithful port of Mouser's recognizer (`core/gesture_recognizer.py`),
/// as a pure value type: feed ``begin()`` on press, ``sample(dx:dy:source:at:)``
/// for every movement, and ``end()`` on release. Time is supplied by the
/// caller, so behavior is deterministic.
///
/// Rules:
/// * **Free phase.** A stroke starts once it is ``GestureConfiguration/directionEpsilon``
///   long, restarts on reversal or after ``GestureConfiguration/commitWindow``, and
///   fires when its dominant axis reaches ``GestureConfiguration/commitDistance`` with
///   bounded off-axis travel over at least four samples (rejecting click jolts).
/// * **Locked phase.** After a swipe the hold locks to that direction: further
///   flicks in the same direction fire after a return stroke; the return
///   stroke itself never fires. A pause longer than
///   ``GestureConfiguration/settle`` unlocks it.
/// * Swipes are at least 90 ms apart. A release with no swipe is a tap.
/// * Device raw XY supersedes event-tap motion within a hold; once a source is
///   used, other sources are ignored.
public struct GestureRecognizer: Hashable, Sendable {
    private enum Constant {
        static let crossFloor = 14.0
        static let refractory = Duration.milliseconds(90)
        static let turnHysteresis = 4.0
        static let minimumSamples = 4
    }

    private enum Axis: Hashable {
        case horizontal
        case vertical
    }

    private struct Lock: Hashable {
        let axis: Axis
        let sign: Double
        var anchor: Double
        var extreme: Double
        var offAxisAtTurn: Double
        var turnTime: Duration
        var returnSeen = false

        mutating func rebase(onAxis: Double, offAxis: Double, at time: Duration) {
            anchor = onAxis
            extreme = onAxis
            offAxisAtTurn = offAxis
            turnTime = time
            returnSeen = false
        }
    }

    /// The tuning in use.
    public let configuration: GestureConfiguration
    /// Whether swipes are recognized at all; when `false` every hold is a tap.
    public let isEnabled: Bool

    /// Whether a hold is in progress.
    public private(set) var isActive = false
    /// Swipes fired during the current (or last) hold.
    public private(set) var fired: [SwipeDirection] = []

    private var source: MotionSource?
    private var lastSampleTime: Duration?
    private var lastFireTime: Duration?
    private var position = (x: 0.0, y: 0.0)
    private var pivot = (x: 0.0, y: 0.0)
    private var pivotTime: Duration?
    private var legPeak = 0.0
    private var legSamples = 0
    private var lock: Lock?

    /// Creates a recognizer.
    public init(configuration: GestureConfiguration = .standard, isEnabled: Bool = true) {
        self.configuration = configuration
        self.isEnabled = isEnabled
    }

    /// Starts a hold, discarding any previous state.
    public mutating func begin() {
        self = GestureRecognizer(configuration: configuration, isEnabled: isEnabled)
        isActive = true
    }

    /// Ends the hold and reports whether it was a tap or produced swipes.
    public mutating func end() -> GestureOutcome {
        guard isActive else { return .none }
        isActive = false
        lock = nil
        return fired.isEmpty ? .tap : .swiped(fired)
    }

    /// Abandons the hold without a tap or further swipes (for example on a
    /// profile switch, permission loss or device disconnect).
    public mutating func cancel() {
        isActive = false
        lock = nil
    }

    /// Feeds one movement delta.
    /// - Returns: The direction of a swipe fired by this sample, if any.
    public mutating func sample(dx: Double, dy: Double, source: MotionSource, at time: Duration) -> SwipeDirection? {
        guard isActive, isEnabled, dx != 0 || dy != 0, accept(source) else { return nil }
        if let last = lastSampleTime, time - last > configuration.settle {
            lock = nil
            resetLeg()
        }
        lastSampleTime = time
        position.x += dx
        position.y += dy
        return lock == nil ? stepFree(time) : stepLocked(time)
    }

    private mutating func accept(_ candidate: MotionSource) -> Bool {
        if source == candidate { return true }
        if source == nil {
            source = candidate
            return true
        }
        guard candidate == .deviceRawXY else { return false }
        source = candidate
        lock = nil
        resetLeg()
        return true
    }

    private mutating func resetLeg() {
        pivot = position
        pivotTime = nil
        legPeak = 0
        legSamples = 0
    }

    private mutating func stepFree(_ time: Duration) -> SwipeDirection? {
        let leg = (x: position.x - pivot.x, y: position.y - pivot.y)
        let length = (leg.x * leg.x + leg.y * leg.y).squareRoot()
        if let start = pivotTime {
            legSamples += 1
            if length < legPeak - configuration.directionEpsilon {
                resetLeg()
                return nil
            }
            legPeak = max(legPeak, length)
            if time - start > configuration.commitWindow {
                resetLeg()
                return nil
            }
        } else {
            guard length >= configuration.directionEpsilon else { return nil }
            pivotTime = time
            legPeak = length
            legSamples = 1
        }
        guard let direction = evaluate(leg), legSamples >= Constant.minimumSamples, fire(direction, at: time) else {
            return nil
        }
        let axis: Axis = direction == .left || direction == .right ? .horizontal : .vertical
        let onAxis = axis == .horizontal ? position.x : position.y
        lock = Lock(
            axis: axis,
            sign: direction == .left || direction == .up ? -1 : 1,
            anchor: onAxis,
            extreme: onAxis,
            offAxisAtTurn: axis == .horizontal ? position.y : position.x,
            turnTime: time
        )
        return direction
    }

    private mutating func stepLocked(_ time: Duration) -> SwipeDirection? {
        guard var state = lock else { return nil }
        defer { lock = state }
        let onAxis = state.axis == .horizontal ? position.x : position.y
        let offAxis = state.axis == .horizontal ? position.y : position.x
        if state.sign * onAxis < state.sign * state.extreme - Constant.turnHysteresis {
            state.extreme = onAxis
            state.offAxisAtTurn = offAxis
            state.turnTime = time
        }
        if state.sign * (state.anchor - state.extreme) >= configuration.minimumReturn {
            state.returnSeen = true
        }
        let flick = state.sign * (onAxis - state.extreme)
        guard state.returnSeen, flick >= configuration.commitDistance else { return nil }
        if time - state.turnTime > configuration.commitWindow {
            state.rebase(onAxis: onAxis, offAxis: offAxis, at: time)
            return nil
        }
        guard abs(offAxis - state.offAxisAtTurn) <= configuration.crossRatio * flick + Constant.crossFloor else {
            return nil
        }
        let direction: SwipeDirection =
            switch (state.axis, state.sign > 0) {
            case (.horizontal, true): .right
            case (.horizontal, false): .left
            case (.vertical, true): .down
            case (.vertical, false): .up
            }
        guard fire(direction, at: time) else { return nil }
        state.rebase(onAxis: onAxis, offAxis: offAxis, at: time)
        return direction
    }

    private func evaluate(_ leg: (x: Double, y: Double)) -> SwipeDirection? {
        let horizontal = abs(leg.x) >= abs(leg.y)
        let dominant = horizontal ? abs(leg.x) : abs(leg.y)
        let cross = horizontal ? abs(leg.y) : abs(leg.x)
        guard dominant >= configuration.commitDistance,
            cross <= configuration.crossRatio * dominant + Constant.crossFloor
        else { return nil }
        if horizontal { return leg.x > 0 ? .right : .left }
        return leg.y > 0 ? .down : .up
    }

    private mutating func fire(_ direction: SwipeDirection, at time: Duration) -> Bool {
        if let last = lastFireTime, time - last < Constant.refractory { return false }
        lastFireTime = time
        fired.append(direction)
        return true
    }

    /// Equality and hashing consider the observable state only.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.isEnabled == rhs.isEnabled
            && lhs.isActive == rhs.isActive && lhs.fired == rhs.fired
    }

    /// Hashes the observable state.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(configuration)
        hasher.combine(isEnabled)
        hasher.combine(isActive)
        hasher.combine(fired)
    }
}
