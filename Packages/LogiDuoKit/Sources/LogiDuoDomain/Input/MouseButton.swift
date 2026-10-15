/// A physical mouse button, independent of how the host learns about presses.
public enum MouseButton: String, CaseIterable, Hashable, Sendable, Codable {
    /// The primary (usually left) button. Never remapped.
    case primary
    /// The secondary (usually right) button. Never remapped.
    case secondary
    /// The middle button or wheel click.
    case middle
    /// The back side button (system button 4).
    case back
    /// The forward side button (system button 5).
    case forward
    /// The thumb gesture button found on MX Master mice.
    case gesture
    /// The wheel mode-shift button that toggles ratchet and free spin.
    case modeShift
    /// A dedicated DPI-switch button.
    case dpiSwitch
    /// An additional thumb button (MX Master 4).
    case thumb
    /// The haptic Sense Panel (MX Master 4).
    case sensePanel

    /// Buttons whose behavior LogiDuo never changes, so the pointer always stays usable.
    public var isProtected: Bool {
        self == .primary || self == .secondary
    }

    /// Whether macOS reports this button as an ordinary mouse event.
    ///
    /// System-reported buttons can be remapped with an event tap alone; every
    /// other button is only visible once the device diverts it over HID++.
    public var isSystemReported: Bool {
        switch self {
        case .primary, .secondary, .middle, .back, .forward: true
        case .gesture, .modeShift, .dpiSwitch, .thumb, .sensePanel: false
        }
    }
}
