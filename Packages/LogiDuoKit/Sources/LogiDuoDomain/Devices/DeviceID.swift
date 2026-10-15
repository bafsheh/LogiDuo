/// The stable logical identity of a device inside LogiDuo.
///
/// Settings, profiles and navigation refer to devices only through this value.
/// It is derived from the physical identity when the firmware reports one, so
/// it survives transport changes (for example a mouse moving from a Bolt
/// receiver to Bluetooth); otherwise it is derived from the endpoint. See
/// ``DeviceIdentityRegistry`` for the reconciliation rules.
public struct DeviceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The opaque identity string; never empty. Never shown to users and never logged in full.
    public let rawValue: String

    /// Creates an identifier, rejecting empty or whitespace-only values.
    public init?(rawValue: String) {
        guard rawValue.contains(where: { !$0.isWhitespace }) else { return nil }
        self.rawValue = rawValue
    }

    /// Creates an identifier from a value the domain derived itself.
    ///
    /// Derived values always start with a fixed, non-empty prefix.
    init(derived rawValue: String) {
        self.rawValue = rawValue
    }

    /// A redacted form safe for logs; it does not reveal serial numbers.
    public var description: String {
        "DeviceID(\(rawValue.count) chars)"
    }
}
