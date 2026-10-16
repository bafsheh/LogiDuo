public import LogiDuoDomain

/// The scroll amounts of one axis in all three units a scroll event carries.
public struct ScrollAxis: Hashable, Sendable {
    /// Lines (`ScrollWheelEventDeltaAxis*`).
    public var lines: Int64
    /// Fixed-point lines (`ScrollWheelEventFixedPtDeltaAxis*`).
    public var fixed: Double
    /// Pixels (`ScrollWheelEventPointDeltaAxis*`).
    public var points: Int64

    /// No movement.
    public static let zero = ScrollAxis(lines: 0, fixed: 0, points: 0)

    /// Creates an axis.
    public init(lines: Int64, fixed: Double, points: Int64) {
        self.lines = lines
        self.fixed = fixed
        self.points = points
    }

    /// Whether the axis moves at all.
    public var isMoving: Bool { lines != 0 || fixed != 0 || points != 0 }

    /// The opposite direction.
    public var inverted: ScrollAxis { ScrollAxis(lines: -lines, fixed: -fixed, points: -points) }
}

/// The parts of a scroll event a transform reads and writes.
public struct ScrollFields: Hashable, Sendable {
    /// Vertical scrolling (axis 1).
    public var vertical: ScrollAxis
    /// Horizontal scrolling (axis 2).
    public var horizontal: ScrollAxis
    /// Trackpad/Magic Mouse gesture phase; non-zero for those devices.
    public var scrollPhase: Int64
    /// Momentum phase; non-zero while momentum scrolling.
    public var momentumPhase: Int64
    /// Whether Shift is held.
    public var shift: Bool

    /// Creates fields.
    public init(vertical: ScrollAxis, horizontal: ScrollAxis, scrollPhase: Int64, momentumPhase: Int64, shift: Bool) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.shift = shift
    }

    /// Whether the event comes from a gesture device (trackpad, Magic Mouse) rather than a wheel.
    public var isGestureScroll: Bool { scrollPhase != 0 || momentumPhase != 0 }
}

/// Applies the scroll preferences to a scroll event. Pure.
///
/// Order: trackpad and Magic Mouse scrolling are left alone when so configured;
/// then Shift turns vertical wheel scrolling horizontal; then inversion applies
/// per axis.
public enum ScrollTransform {
    /// The changed fields, or `nil` if the event stays as it is.
    public static func apply(_ settings: ScrollSettings, to fields: ScrollFields) -> ScrollFields? {
        if settings.ignoreTrackpad, fields.isGestureScroll { return nil }
        var result = fields
        if settings.shiftScrollsHorizontally, fields.shift, fields.vertical.isMoving, !fields.horizontal.isMoving {
            result.horizontal = fields.vertical
            result.vertical = .zero
        }
        if settings.invertVertical { result.vertical = result.vertical.inverted }
        if settings.invertHorizontal { result.horizontal = result.horizontal.inverted }
        return result == fields ? nil : result
    }
}
