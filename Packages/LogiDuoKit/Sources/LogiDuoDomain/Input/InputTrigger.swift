/// A direction of a swipe performed while holding a button.
public enum SwipeDirection: String, CaseIterable, Hashable, Sendable, Codable {
    /// Up.
    case up
    /// Down.
    case down
    /// Left.
    case left
    /// Right.
    case right
}

/// A direction of horizontal scrolling (thumbwheel or wheel tilt).
public enum HorizontalScrollDirection: String, CaseIterable, Hashable, Sendable, Codable {
    /// Scrolling left.
    case left
    /// Scrolling right.
    case right
}

/// A physical input that a mapping can respond to.
public enum InputTrigger: Hashable, Sendable, Codable {
    /// Pressing and releasing a button. When the same button also has
    /// ``swipe(_:_:)`` mappings, this fires only for a release without a swipe (a tap).
    case press(MouseButton)
    /// Moving the mouse in `direction` while holding the button.
    case swipe(MouseButton, SwipeDirection)
    /// Scrolling horizontally.
    case horizontalScroll(HorizontalScrollDirection)

    /// The button involved, if any.
    public var button: MouseButton? {
        switch self {
        case .press(let button), .swipe(let button, _): button
        case .horizontalScroll: nil
        }
    }
}
