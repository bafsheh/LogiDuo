/// What is known about one capability of a device.
///
/// Capabilities start ``undiscovered`` and become ``supported(_:)`` or
/// ``unsupported`` once the device has been queried. A UI must only offer a
/// control for a capability that is ``supported(_:)``.
public enum CapabilityStatus<Detail: Hashable & Sendable>: Hashable, Sendable {
    /// The device has not been queried yet.
    case undiscovered
    /// The device does not provide the capability.
    case unsupported
    /// The device provides the capability with the given characteristics.
    case supported(Detail)

    /// Whether the capability is known to be available.
    public var isSupported: Bool { detail != nil }

    /// Whether the capability has been determined either way.
    public var isDiscovered: Bool { self != .undiscovered }

    /// The capability's characteristics, if supported.
    public var detail: Detail? {
        if case .supported(let detail) = self { detail } else { nil }
    }

    /// Combines this status with a newer one.
    ///
    /// A discovered `newer` value always wins — including `.unsupported`
    /// overriding a catalog expectation. An undiscovered `newer` value never
    /// erases what is already known.
    public func refined(by newer: Self) -> Self {
        newer.isDiscovered ? newer : self
    }
}

/// The detail type of capabilities that are either present or absent.
public struct Presence: Hashable, Sendable, Codable {
    /// The only value.
    public static let present = Presence()

    private init() {}
}

/// Availability of an operation that depends on capabilities.
public enum Availability: Hashable, Sendable {
    /// The operation can be performed.
    case available
    /// The operation can never be performed on this device.
    case unavailable
    /// Not known until the device's capabilities are discovered.
    case pending
}
