public import LogiDuoDomain

/// The fields of a tapped event that LogiDuo reads, copied out of the `CGEvent`.
///
/// Plain values keep classification pure and testable without CoreGraphics.
public struct TapEventSnapshot: Hashable, Sendable {
    /// The event kinds the tap can deliver.
    public enum Kind: Hashable, Sendable {
        /// A non-primary, non-secondary button went down.
        case otherMouseDown
        /// A non-primary, non-secondary button went up.
        case otherMouseUp
        /// Pointer movement while such a button is held.
        case otherMouseDragged
        /// Pointer movement with no button held.
        case mouseMoved
        /// Scroll wheel, trackpad or Magic Mouse scrolling.
        case scrollWheel
        /// macOS disabled the tap because a callback was too slow.
        case tapDisabledByTimeout
        /// macOS disabled the tap because of user input (for example secure input).
        case tapDisabledByUserInput
        /// Anything else, including primary and secondary buttons; always passed through.
        case other
    }

    /// The kind of event.
    public let kind: Kind
    /// `kCGMouseEventButtonNumber` (2 middle, 3 back, 4 forward).
    public let buttonNumber: Int64
    /// `kCGEventSourceUserData`; LogiDuo's own events carry ``SyntheticEventMarker/value``.
    public let userData: Int64
    /// Pointer delta X (`kCGMouseEventDeltaX`).
    public let deltaX: Int64
    /// Pointer delta Y (`kCGMouseEventDeltaY`).
    public let deltaY: Int64
    /// Horizontal scroll (`kCGScrollWheelEventFixedPtDeltaAxis2`); positive means right.
    public let horizontalScroll: Double
    /// `kCGScrollWheelEventScrollPhase`; non-zero for trackpad and Magic Mouse gestures.
    public let scrollPhase: Int64
    /// `kCGScrollWheelEventMomentumPhase`; non-zero for momentum scrolling.
    public let momentumPhase: Int64

    /// Creates a snapshot; unspecified fields are zero.
    public init(
        kind: Kind,
        buttonNumber: Int64 = 0,
        userData: Int64 = 0,
        deltaX: Int64 = 0,
        deltaY: Int64 = 0,
        horizontalScroll: Double = 0,
        scrollPhase: Int64 = 0,
        momentumPhase: Int64 = 0
    ) {
        self.kind = kind
        self.buttonNumber = buttonNumber
        self.userData = userData
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.horizontalScroll = horizontalScroll
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
    }
}

/// What a tapped event means to LogiDuo.
public enum TapClassification: Hashable, Sendable {
    /// An input event for the interpreter.
    case input(InputEvent)
    /// Not LogiDuo's concern; deliver unchanged.
    case ignore
    /// A tap lifecycle signal for the supervisor.
    case signal(EventTapSignal)
}

/// Maps tapped events to domain input events.
///
/// Rules: LogiDuo's own synthetic events are ignored (no recursion); only
/// buttons 2, 3 and 4 are interpreted; trackpad and Magic Mouse scrolling
/// (non-zero scroll or momentum phase) is ignored so system gestures keep
/// working; vertical scrolling is ignored.
public enum TapEventClassifier {
    /// Classifies `snapshot`.
    public static func classify(_ snapshot: TapEventSnapshot) -> TapClassification {
        switch snapshot.kind {
        case .tapDisabledByTimeout: return .signal(.disabledByTimeout)
        case .tapDisabledByUserInput: return .signal(.disabledByUserInput)
        default: break
        }
        guard !SyntheticEventMarker.isLogiDuoEvent(userData: snapshot.userData) else { return .ignore }
        switch snapshot.kind {
        case .otherMouseDown:
            return button(snapshot.buttonNumber).map { .input(.buttonDown($0)) } ?? .ignore
        case .otherMouseUp:
            return button(snapshot.buttonNumber).map { .input(.buttonUp($0)) } ?? .ignore
        case .otherMouseDragged, .mouseMoved:
            guard snapshot.deltaX != 0 || snapshot.deltaY != 0 else { return .ignore }
            return .input(.motion(dx: Double(snapshot.deltaX), dy: Double(snapshot.deltaY), source: .eventTap))
        case .scrollWheel:
            guard snapshot.scrollPhase == 0, snapshot.momentumPhase == 0, snapshot.horizontalScroll != 0 else {
                return .ignore
            }
            let direction: HorizontalScrollDirection = snapshot.horizontalScroll > 0 ? .right : .left
            return .input(.horizontalScroll(direction, delta: snapshot.horizontalScroll))
        case .tapDisabledByTimeout, .tapDisabledByUserInput, .other:
            return .ignore
        }
    }

    /// The domain button for a CoreGraphics button number; primary (0) and secondary (1) are never mapped.
    static func button(_ number: Int64) -> MouseButton? {
        switch number {
        case 2: .middle
        case 3: .back
        case 4: .forward
        default: nil
        }
    }
}
