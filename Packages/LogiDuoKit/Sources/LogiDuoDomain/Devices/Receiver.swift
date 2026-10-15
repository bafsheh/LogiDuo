/// An opaque, stable identity for a physical receiver.
///
/// Derived by infrastructure from the receiver's own serial number when
/// available, otherwise from its host location. Never shown or logged in full.
public struct ReceiverID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The opaque identity string; never empty.
    public let rawValue: String

    /// Creates a receiver identity, rejecting empty or whitespace-only values.
    public init?(rawValue: String) {
        guard rawValue.contains(where: { !$0.isWhitespace }) else { return nil }
        self.rawValue = rawValue
    }

    /// A redacted form safe for logs.
    public var description: String { "ReceiverID(\(rawValue.count) chars)" }
}

/// A pairing slot on a receiver, numbered 1 through 6.
///
/// Slot numbers match HID++ device indexes `0x01...0x06`; index `0xFF`
/// (the receiver itself or a directly connected device) is not a slot.
public struct ReceiverSlot: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// The valid slot numbers.
    public static let validRange: ClosedRange<UInt8> = 1...6

    /// The slot number.
    public let rawValue: UInt8

    /// Creates a slot, rejecting numbers outside ``validRange``.
    public init?(rawValue: UInt8) {
        guard Self.validRange.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Orders slots by number.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `slot N`.
    public var description: String { "slot \(rawValue)" }
}

/// A connected receiver.
public struct ReceiverDescriptor: Hashable, Sendable, Codable {
    /// The receiver's physical identity.
    public let id: ReceiverID
    /// The receiver family.
    public let kind: ReceiverKind
    /// The receiver's USB vendor/product pair.
    public let hardware: HardwareIdentifier

    /// Creates a receiver descriptor; the kind is classified from `hardware`.
    public init(id: ReceiverID, hardware: HardwareIdentifier) {
        self.id = id
        self.hardware = hardware
        self.kind = ReceiverKind(product: hardware.product)
    }
}
