/// A device's firmware-reported unit identifier (HID++ feature 0x0003).
///
/// Unique per unit within a model and identical on every transport.
/// It is serial-like data: the description is redacted.
public struct UnitID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The 32-bit unit identifier.
    public let rawValue: UInt32

    /// Creates a unit identifier.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Redacted; unit identifiers must not appear in logs.
    public var description: String { "UnitID(redacted)" }
}

/// A device's firmware-reported model identifier (HID++ feature 0x0003).
///
/// The firmware reports the same model identifier regardless of the transport
/// in use, unlike ``ProductID`` which changes between Bluetooth and receivers.
/// Only the low 48 bits are significant.
public struct ModelID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The significant bits of a model identifier.
    public static let significantBits: UInt64 = 0xFFFF_FFFF_FFFF

    /// The 48-bit model identifier.
    public let rawValue: UInt64

    /// Creates a model identifier, rejecting values wider than 48 bits.
    public init?(rawValue: UInt64) {
        guard rawValue & ~Self.significantBits == 0 else { return nil }
        self.rawValue = rawValue
    }

    /// Hexadecimal form (12 digits).
    public var description: String { hexString(rawValue, digits: 12) }
}

/// The physical identity of a device: who it is, independent of how it is connected.
///
/// Only available when the firmware reports it; older devices and early
/// connection stages have no physical identity and fall back to their endpoint.
public struct PhysicalDeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The device model.
    public let model: ModelID
    /// The unit within that model.
    public let unit: UnitID

    /// Creates a physical identity.
    public init(model: ModelID, unit: UnitID) {
        self.model = model
        self.unit = unit
    }

    /// Redacted; reveals the model only.
    public var description: String { "PhysicalDeviceID(model \(model), unit redacted)" }
}
