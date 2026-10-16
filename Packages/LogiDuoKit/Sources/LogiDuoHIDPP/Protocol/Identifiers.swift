public import LogiDuoDomain

/// The HID++ device index (byte 1 of every report).
///
/// `0xFF` addresses a directly connected device (Bluetooth, USB cable) or the
/// receiver itself; `0x01...0x06` address devices paired to a receiver.
public struct DeviceIndex: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// A directly connected device, or the receiver itself.
    public static let direct = DeviceIndex(rawValue: 0xFF)

    /// The raw index byte.
    public let rawValue: UInt8

    /// Creates an index from its raw byte.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The index of a device paired in `slot`.
    public init(receiverSlot slot: ReceiverSlot) {
        self.rawValue = slot.rawValue
    }

    /// The receiver slot this index addresses, if any.
    public var receiverSlot: ReceiverSlot? { ReceiverSlot(rawValue: rawValue) }

    /// Hexadecimal form, for example `0xFF`.
    public var description: String { "0x" + hex(rawValue) }
}

/// A position in a device's feature table (HID++ 2.0, byte 2).
///
/// Index `0x00` is always the Root feature. `0xFF` is reserved for error reports.
public struct FeatureIndex: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The Root feature, always at index 0.
    public static let root = FeatureIndex(rawValue: 0x00)

    /// The raw index byte.
    public let rawValue: UInt8

    /// Creates an index from its raw byte.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Hexadecimal form.
    public var description: String { "0x" + hex(rawValue) }
}

/// A function within a feature: the high nibble of byte 3 (0...15).
public struct FunctionID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The function number.
    public let rawValue: UInt8

    /// Creates a function identifier, rejecting values above 15.
    public init?(rawValue: UInt8) {
        guard rawValue <= 0x0F else { return nil }
        self.rawValue = rawValue
    }

    init(nibble: UInt8) {
        self.rawValue = nibble & 0x0F
    }

    /// `fnN`.
    public var description: String { "fn\(rawValue)" }
}

/// The software identifier: the low nibble of byte 3 (0...15).
///
/// Devices echo the identifier of the request in their reply. `0` is used by
/// devices for unsolicited notifications, so requests use 1...15.
public struct SoftwareID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The identifier devices use for notifications.
    public static let notification = SoftwareID(nibble: 0)
    /// The identifiers available to requests.
    public static let requestRange: ClosedRange<UInt8> = 1...15

    /// The identifier value.
    public let rawValue: UInt8

    /// Creates a software identifier, rejecting values above 15.
    public init?(rawValue: UInt8) {
        guard rawValue <= 0x0F else { return nil }
        self.rawValue = rawValue
    }

    init(nibble: UInt8) {
        self.rawValue = nibble & 0x0F
    }

    /// Whether a device may have sent this identifier unprompted.
    public var isNotification: Bool { rawValue == 0 }

    /// `swN`.
    public var description: String { "sw\(rawValue)" }
}

/// A HID++ 2.0 feature identifier, as listed in the Root feature.
public struct FeatureID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// Root (0x0000): feature lookup and protocol version.
    public static let root = FeatureID(rawValue: 0x0000)
    /// FeatureSet (0x0001): enumerates the feature table.
    public static let featureSet = FeatureID(rawValue: 0x0001)
    /// DeviceInformation (0x0003): unit and model identifiers, firmware versions.
    public static let deviceInformation = FeatureID(rawValue: 0x0003)
    /// DeviceNameType (0x0005): marketing name and device type.
    public static let deviceName = FeatureID(rawValue: 0x0005)
    /// BatteryStatus (0x1000).
    public static let batteryStatus = FeatureID(rawValue: 0x1000)
    /// UnifiedBattery (0x1004).
    public static let unifiedBattery = FeatureID(rawValue: 0x1004)
    /// ReprogControlsV4 (0x1B04): button reporting and diversion.
    public static let reprogControlsV4 = FeatureID(rawValue: 0x1B04)
    /// SmartShift (0x2110).
    public static let smartShift = FeatureID(rawValue: 0x2110)
    /// SmartShift with tunable torque (0x2111).
    public static let smartShiftEnhanced = FeatureID(rawValue: 0x2111)
    /// High-resolution wheel (0x2121).
    public static let hiResWheel = FeatureID(rawValue: 0x2121)
    /// Thumbwheel (0x2150).
    public static let thumbwheel = FeatureID(rawValue: 0x2150)
    /// AdjustableDPI (0x2201).
    public static let adjustableDPI = FeatureID(rawValue: 0x2201)

    /// The 16-bit feature identifier.
    public let rawValue: UInt16

    /// Creates a feature identifier.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Big-endian bytes, as sent on the wire.
    public var bytes: [UInt8] { [UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)] }

    /// Hexadecimal form, for example `0x1B04`.
    public var description: String { "0x" + hex(UInt8(rawValue >> 8)) + hex(UInt8(rawValue & 0xFF)) }
}

func hex(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16, uppercase: true)
    return digits.count == 1 ? "0" + digits : digits
}
