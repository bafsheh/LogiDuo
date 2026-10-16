/// A HID++ 2.0 message: a reply to a request or a device notification.
public struct HIDPPMessage: Hashable, Sendable {
    /// The report type the message arrived in.
    public let reportType: HIDPPReportType
    /// The addressed device.
    public let deviceIndex: DeviceIndex
    /// The feature the message belongs to.
    public let featureIndex: FeatureIndex
    /// The function within the feature.
    public let function: FunctionID
    /// The echoed software identifier; ``SoftwareID/notification`` for notifications.
    public let softwareID: SoftwareID
    /// Function parameters (the report payload, zero-padded).
    public let parameters: [UInt8]
}

/// A HID++ 2.0 error code.
public struct HIDPP20ErrorCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// No error (should not appear in an error report).
    public static let noError = Self(rawValue: 0x00)
    /// Unspecified error.
    public static let unknown = Self(rawValue: 0x01)
    /// A parameter is invalid.
    public static let invalidArgument = Self(rawValue: 0x02)
    /// A parameter is out of range.
    public static let outOfRange = Self(rawValue: 0x03)
    /// Hardware failure.
    public static let hardwareError = Self(rawValue: 0x04)
    /// Vendor-specific error.
    public static let logitechInternal = Self(rawValue: 0x05)
    /// The feature index does not exist.
    public static let invalidFeatureIndex = Self(rawValue: 0x06)
    /// The function does not exist in the feature.
    public static let invalidFunction = Self(rawValue: 0x07)
    /// The device is busy; retrying later may succeed.
    public static let busy = Self(rawValue: 0x08)
    /// The request is not supported.
    public static let unsupported = Self(rawValue: 0x09)

    /// The raw code.
    public let rawValue: UInt8

    /// Creates a code.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Whether retrying the same request later may succeed.
    public var isTransient: Bool { self == .busy }

    /// Name and value, for example `busy (0x08)`.
    public var description: String {
        let names: [UInt8: String] = [
            0x00: "noError", 0x01: "unknown", 0x02: "invalidArgument", 0x03: "outOfRange",
            0x04: "hardwareError", 0x05: "logitechInternal", 0x06: "invalidFeatureIndex",
            0x07: "invalidFunction", 0x08: "busy", 0x09: "unsupported",
        ]
        return "\(names[rawValue] ?? "unrecognized") (0x\(hex(rawValue)))"
    }
}

/// A HID++ 1.0 error code (reported by receivers and HID++ 1.0 devices).
public struct HIDPP10ErrorCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The sub-ID (or, for HID++ 2.0 requests, the feature index) is invalid.
    public static let invalidSubID = Self(rawValue: 0x01)
    /// The address (or function) is invalid.
    public static let invalidAddress = Self(rawValue: 0x02)
    /// A value is invalid.
    public static let invalidValue = Self(rawValue: 0x03)
    /// Connection failed.
    public static let connectionFailed = Self(rawValue: 0x04)
    /// Too many devices.
    public static let tooManyDevices = Self(rawValue: 0x05)
    /// Already exists.
    public static let alreadyExists = Self(rawValue: 0x06)
    /// Busy; retrying later may succeed.
    public static let busy = Self(rawValue: 0x07)
    /// No device is paired at the addressed index, or it is not reachable.
    public static let unknownDevice = Self(rawValue: 0x08)
    /// Resource error.
    public static let resourceError = Self(rawValue: 0x09)
    /// The request is unavailable.
    public static let requestUnavailable = Self(rawValue: 0x0A)
    /// A parameter value is invalid.
    public static let invalidParameterValue = Self(rawValue: 0x0B)
    /// Wrong PIN code.
    public static let wrongPINCode = Self(rawValue: 0x0C)

    /// The raw code.
    public let rawValue: UInt8

    /// Creates a code.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Whether retrying the same request later may succeed.
    public var isTransient: Bool { self == .busy }

    /// Name and value.
    public var description: String {
        let names: [UInt8: String] = [
            0x01: "invalidSubID", 0x02: "invalidAddress", 0x03: "invalidValue", 0x04: "connectionFailed",
            0x05: "tooManyDevices", 0x06: "alreadyExists", 0x07: "busy", 0x08: "unknownDevice",
            0x09: "resourceError", 0x0A: "requestUnavailable", 0x0B: "invalidParameterValue",
            0x0C: "wrongPINCode",
        ]
        return "\(names[rawValue] ?? "unrecognized") (0x\(hex(rawValue)))"
    }
}

/// A HID++ 2.0 error report: `[id] [device] FF [feature index] [function|sw] [code] …`.
///
/// It echoes the feature index, function and software identifier of the
/// failed request, so it can be attributed to exactly one request.
public struct HIDPP20ErrorReport: Hashable, Sendable {
    /// The addressed device.
    public let deviceIndex: DeviceIndex
    /// The feature index of the failed request.
    public let featureIndex: FeatureIndex
    /// The function of the failed request.
    public let function: FunctionID
    /// The software identifier of the failed request.
    public let softwareID: SoftwareID
    /// The error code.
    public let code: HIDPP20ErrorCode
}

/// A HID++ 1.0 error report: `10 [device] 8F [sub-ID] [address] [code] 00`.
///
/// Receivers answer this way for an empty slot or an unreachable device. The
/// echoed sub-ID and address are byte 2 and byte 3 of the failed request, so
/// for a HID++ 2.0 request they are its feature index and function/sw byte.
public struct HIDPP10ErrorReport: Hashable, Sendable {
    /// The addressed device.
    public let deviceIndex: DeviceIndex
    /// Byte 2 of the failed request.
    public let subID: UInt8
    /// Byte 3 of the failed request.
    public let address: UInt8
    /// The error code.
    public let code: HIDPP10ErrorCode
}

/// The interpretation of an inbound report.
public enum HIDPPInbound: Hashable, Sendable {
    /// Marker values in byte 2 of HID++ error reports.
    enum Marker {
        static let hidpp20Error: UInt8 = 0xFF
        static let hidpp10Error: UInt8 = 0x8F
        /// HID++ 1.0 register sub-IDs occupy 0x80...0xFE; feature indexes never do.
        static let hidpp10RegisterRange: ClosedRange<UInt8> = 0x80...0xFE
    }

    /// A HID++ 2.0 reply or notification.
    case message(HIDPPMessage)
    /// A HID++ 2.0 error report.
    case featureError(HIDPP20ErrorReport)
    /// A HID++ 1.0 error report.
    case legacyError(HIDPP10ErrorReport)
    /// Other HID++ 1.0 traffic (register access replies), not interpreted here.
    case legacy(HIDPPReport)

    /// Interprets `report`.
    public init(_ report: HIDPPReport) {
        switch report.subID {
        case Marker.hidpp20Error:
            self = .featureError(
                HIDPP20ErrorReport(
                    deviceIndex: report.deviceIndex,
                    featureIndex: FeatureIndex(rawValue: report.address),
                    function: FunctionID(nibble: report.payload[0] >> 4),
                    softwareID: SoftwareID(nibble: report.payload[0]),
                    code: HIDPP20ErrorCode(rawValue: report.payload[1])
                )
            )
        case Marker.hidpp10Error:
            self = .legacyError(
                HIDPP10ErrorReport(
                    deviceIndex: report.deviceIndex,
                    subID: report.address,
                    address: report.payload[0],
                    code: HIDPP10ErrorCode(rawValue: report.payload[1])
                )
            )
        case Marker.hidpp10RegisterRange:
            self = .legacy(report)
        default:
            self = .message(
                HIDPPMessage(
                    reportType: report.type,
                    deviceIndex: report.deviceIndex,
                    featureIndex: FeatureIndex(rawValue: report.subID),
                    function: FunctionID(nibble: report.address >> 4),
                    softwareID: SoftwareID(nibble: report.address),
                    parameters: report.payload
                )
            )
        }
    }
}
