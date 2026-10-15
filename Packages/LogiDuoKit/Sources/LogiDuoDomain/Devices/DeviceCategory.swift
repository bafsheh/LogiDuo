/// What kind of hardware a device is.
///
/// The category selects which capability model applies; it never implies that a
/// particular capability is available.
public enum DeviceCategory: String, CaseIterable, Hashable, Sendable, Codable {
    /// A mouse or trackball.
    case mouse
    /// A keyboard.
    case keyboard
    /// A wireless receiver that hosts paired devices (Bolt, Unifying, …).
    case receiver
    /// A Logitech HID device that is not yet classified. No features are offered for it.
    case unclassified
}
