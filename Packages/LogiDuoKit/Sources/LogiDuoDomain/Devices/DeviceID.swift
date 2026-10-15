/// A stable, opaque identifier for a physical Logitech device.
///
/// The identifier survives reconnects and transport changes (for example a
/// mouse moving from a Bolt receiver to Bluetooth) whenever the hardware
/// reports a unit identity. How the raw value is derived is an infrastructure
/// concern; the domain only relies on equality and stability.
public struct DeviceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The opaque identity string. Never shown to users and never logged in full.
    public let rawValue: String

    /// Creates an identifier from a raw value.
    /// - Parameter rawValue: A non-empty identity string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A redacted form safe for logs; it does not reveal serial numbers.
    public var description: String {
        "DeviceID(\(rawValue.count) chars)"
    }
}
