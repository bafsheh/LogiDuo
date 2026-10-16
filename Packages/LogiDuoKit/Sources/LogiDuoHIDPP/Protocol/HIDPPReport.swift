/// A HID++ report type, identified by the HID report ID (byte 0).
public enum HIDPPReportType: UInt8, CaseIterable, Hashable, Sendable {
    /// Short report: 7 bytes. Used by receivers and HID++ 1.0.
    case short = 0x10
    /// Long report: 20 bytes. The only output type Bluetooth LE devices accept.
    case long = 0x11
    /// Very long report: 64 bytes.
    case veryLong = 0x12

    /// Size of the header: report ID, device index, sub-ID/feature index, address/function byte.
    public static let headerLength = 4

    /// Total length in bytes, including the report ID.
    public var length: Int {
        switch self {
        case .short: 7
        case .long: 20
        case .veryLong: 64
        }
    }

    /// Bytes available after the header.
    public var payloadCapacity: Int { length - Self.headerLength }
}

/// A raw HID++ report.
///
/// Byte layout (all report types):
/// ```
/// [0] report ID   (0x10 short, 0x11 long, 0x12 very long)
/// [1] device index
/// [2] sub-ID      (HID++ 1.0) | feature index (HID++ 2.0)
/// [3] address     (HID++ 1.0) | function << 4 | software ID (HID++ 2.0)
/// [4...] payload, zero-padded to the report length
/// ```
/// The raw form does not decide between HID++ 1.0 and 2.0; see ``HIDPPInbound``.
public struct HIDPPReport: Hashable, Sendable {
    /// The report type.
    public let type: HIDPPReportType
    /// Byte 1.
    public let deviceIndex: DeviceIndex
    /// Byte 2.
    public let subID: UInt8
    /// Byte 3.
    public let address: UInt8
    /// The payload, always exactly ``HIDPPReportType/payloadCapacity`` bytes.
    public let payload: [UInt8]

    /// Creates a report, zero-padding `payload`.
    /// - Throws: ``HIDPPFrameError/payloadTooLong(capacity:actual:)`` if `payload` does not fit.
    public init(
        type: HIDPPReportType,
        deviceIndex: DeviceIndex,
        subID: UInt8,
        address: UInt8,
        payload: [UInt8] = []
    ) throws(HIDPPFrameError) {
        guard payload.count <= type.payloadCapacity else {
            throw .payloadTooLong(capacity: type.payloadCapacity, actual: payload.count)
        }
        self.type = type
        self.deviceIndex = deviceIndex
        self.subID = subID
        self.address = address
        self.payload = payload + Array(repeating: 0, count: type.payloadCapacity - payload.count)
    }

    /// The complete report, including the report ID.
    public var bytes: [UInt8] {
        [type.rawValue, deviceIndex.rawValue, subID, address] + payload
    }
}

/// Why bytes could not be framed as a HID++ report.
public enum HIDPPFrameError: Error, Hashable, Sendable {
    /// The buffer was empty.
    case empty
    /// The first byte is not a HID++ report ID.
    case unknownReportID(UInt8)
    /// The buffer length does not match the report type (truncated or over-long).
    case lengthMismatch(HIDPPReportType, expected: Int, actual: Int)
    /// A buffer without a report ID has a length that matches no report type.
    case unrecognizedLength(Int)
    /// The payload does not fit the report type.
    case payloadTooLong(capacity: Int, actual: Int)
    /// The transport cannot send this report type.
    case unsupportedOutputType(HIDPPReportType)
}

/// How one transport frames HID++ reports.
///
/// Transports differ: Bluetooth LE devices accept only long output reports,
/// receivers accept short and long ones, and some HID stacks strip the
/// report ID from input buffers. Decoding is strict: a buffer must have
/// exactly the length of its report type.
public struct HIDPPFraming: Hashable, Sendable {
    /// A Bluetooth LE HID++ collection: long output only; inputs carry the report ID.
    public static let bluetoothLowEnergy = HIDPPFraming(outputTypes: [.long], inputIncludesReportID: true)
    /// A USB receiver: short and long output; inputs carry the report ID.
    public static let receiver = HIDPPFraming(outputTypes: [.short, .long], inputIncludesReportID: true)

    /// Report types the transport can send.
    public let outputTypes: Set<HIDPPReportType>
    /// Whether input buffers start with the report ID.
    public let inputIncludesReportID: Bool

    /// Creates a framing description.
    public init(outputTypes: Set<HIDPPReportType>, inputIncludesReportID: Bool) {
        self.outputTypes = outputTypes
        self.inputIncludesReportID = inputIncludesReportID
    }

    /// The bytes to hand to the transport for `report`.
    /// - Throws: ``HIDPPFrameError/unsupportedOutputType(_:)`` if the transport cannot send it.
    public func encode(_ report: HIDPPReport) throws(HIDPPFrameError) -> [UInt8] {
        guard outputTypes.contains(report.type) else { throw .unsupportedOutputType(report.type) }
        return report.bytes
    }

    /// Decodes an input buffer.
    /// - Throws: ``HIDPPFrameError`` for empty, unknown, truncated or over-long buffers.
    public func decode(_ bytes: [UInt8]) throws(HIDPPFrameError) -> HIDPPReport {
        guard let first = bytes.first else { throw .empty }
        let type: HIDPPReportType
        let body: ArraySlice<UInt8>
        if inputIncludesReportID {
            guard let declared = HIDPPReportType(rawValue: first) else { throw .unknownReportID(first) }
            guard bytes.count == declared.length else {
                throw .lengthMismatch(declared, expected: declared.length, actual: bytes.count)
            }
            type = declared
            body = bytes.dropFirst()
        } else {
            guard let inferred = HIDPPReportType.allCases.first(where: { $0.length - 1 == bytes.count }) else {
                throw .unrecognizedLength(bytes.count)
            }
            type = inferred
            body = bytes[...]
        }
        let header = Array(body.prefix(3))
        return try HIDPPReport(
            type: type,
            deviceIndex: DeviceIndex(rawValue: header[0]),
            subID: header[1],
            address: header[2],
            payload: Array(body.dropFirst(3))
        )
    }
}
