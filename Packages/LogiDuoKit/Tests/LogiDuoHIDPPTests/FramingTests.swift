import LogiDuoDomain
import LogiDuoHIDPP
import Testing

@Suite("HID++ framing")
struct FramingTests {
    private let framing = HIDPPFraming.receiver

    @Test(
        "report types have the HID++ lengths",
        arguments: [
            (HIDPPReportType.short, 7, 3), (.long, 20, 16), (.veryLong, 64, 60),
        ]
    )
    func lengths(type: HIDPPReportType, length: Int, capacity: Int) {
        #expect(type.length == length)
        #expect(type.payloadCapacity == capacity)
    }

    @Test("decodes every report type at its exact length", arguments: HIDPPReportType.allCases)
    func exactLength(type: HIDPPReportType) throws {
        let bytes = [type.rawValue, 0x01, 0x02, 0x03] + Array(repeating: 0xAB, count: type.payloadCapacity)
        let report = try HIDPPFraming(outputTypes: Set(HIDPPReportType.allCases), inputIncludesReportID: true)
            .decode(bytes)

        #expect(report.type == type)
        #expect(report.deviceIndex == DeviceIndex(rawValue: 0x01))
        #expect(report.subID == 0x02)
        #expect(report.address == 0x03)
        #expect(report.bytes == bytes)
    }

    @Test("rejects truncated and over-long reports", arguments: [6, 19, 21, 63, 65])
    func wrongLengths(length: Int) {
        let type: HIDPPReportType = length < 10 ? .short : (length < 40 ? .long : .veryLong)
        let bytes = [type.rawValue] + Array(repeating: 0, count: length - 1)
        #expect(throws: HIDPPFrameError.lengthMismatch(type, expected: type.length, actual: length)) {
            try framing.decode(bytes)
        }
    }

    @Test("rejects empty buffers and unknown report IDs")
    func garbage() {
        #expect(throws: HIDPPFrameError.empty) { try framing.decode([]) }
        #expect(throws: HIDPPFrameError.unknownReportID(0x20)) { try framing.decode([0x20, 0, 0, 0, 0, 0, 0]) }
        #expect(throws: HIDPPFrameError.unknownReportID(0x01)) { try framing.decode(Array(repeating: 1, count: 20)) }
    }

    @Test("infers the type from the length when the report ID is stripped")
    func strippedReportID() throws {
        let stripped = HIDPPFraming(outputTypes: [.long], inputIncludesReportID: false)
        let report = try stripped.decode(Array(hexBytes("FF 09 00 00 C3 …", padTo: 19)))

        #expect(report.type == .long)
        #expect(report.deviceIndex == .direct)
        #expect(report.subID == 0x09)
        #expect(Array(report.payload.prefix(2)) == [0x00, 0xC3])
        #expect(throws: HIDPPFrameError.unrecognizedLength(5)) { try stripped.decode([0xFF, 0x09, 0, 0, 0xC3]) }
    }

    @Test("pads payloads and rejects ones that do not fit")
    func payloadBounds() throws {
        let report = try HIDPPReport(type: .short, deviceIndex: .direct, subID: 0x81, address: 0x02, payload: [1])
        #expect(report.bytes == [0x10, 0xFF, 0x81, 0x02, 0x01, 0x00, 0x00])
        #expect(throws: HIDPPFrameError.payloadTooLong(capacity: 3, actual: 4)) {
            try HIDPPReport(type: .short, deviceIndex: .direct, subID: 0, address: 0, payload: [1, 2, 3, 4])
        }
    }

    @Test("refuses to send report types the transport does not support")
    func outputTypes() throws {
        let short = try HIDPPReport(type: .short, deviceIndex: .direct, subID: 0x81, address: 0x02)
        #expect(throws: HIDPPFrameError.unsupportedOutputType(.short)) {
            try HIDPPFraming.bluetoothLowEnergy.encode(short)
        }
        #expect(try HIDPPFraming.receiver.encode(short) == short.bytes)
    }

    @Test("identifier boundaries")
    func identifierBounds() throws {
        #expect(FunctionID(rawValue: 15) != nil)
        #expect(FunctionID(rawValue: 16) == nil)
        #expect(SoftwareID(rawValue: 15) != nil)
        #expect(SoftwareID(rawValue: 16) == nil)
        #expect(SoftwareID.notification.isNotification)
        #expect(DeviceIndex.direct.receiverSlot == nil)
        #expect(DeviceIndex(rawValue: 0).receiverSlot == nil)
        let slot = try #require(ReceiverSlot(rawValue: 6))
        #expect(DeviceIndex(receiverSlot: slot).rawValue == 6)
        #expect(FeatureID.reprogControlsV4.bytes == [0x1B, 0x04])
        #expect(FeatureID.reprogControlsV4.description == "0x1B04")
    }

    @Test("requests are bounded by the long payload")
    func requestBounds() throws {
        let function = try #require(FunctionID(rawValue: 1))
        #expect(throws: HIDPPFrameError.payloadTooLong(capacity: 16, actual: 17)) {
            try HIDPPRequest(
                deviceIndex: .direct,
                featureIndex: .root,
                function: function,
                parameters: Array(repeating: 0, count: 17),
                kind: .read
            )
        }
    }
}

@Suite("HID++ inbound interpretation")
struct InboundTests {
    private let framing = HIDPPFraming.receiver

    @Test("a HID++ 2.0 error report echoes the failed request")
    func featureError() throws {
        guard case .featureError(let error) = HIDPPInbound(try framing.decode(hexBytes("11 02 FF 0B 2A 08 …"))) else {
            Issue.record("expected a HID++ 2.0 error")
            return
        }
        #expect(error.deviceIndex == DeviceIndex(rawValue: 2))
        #expect(error.featureIndex == FeatureIndex(rawValue: 0x0B))
        #expect(error.function == FunctionID(rawValue: 2))
        #expect(error.softwareID == SoftwareID(rawValue: 0x0A))
        #expect(error.code == .busy && error.code.isTransient)
    }

    @Test("a HID++ 1.0 error report (0x8F) echoes the failed request bytes")
    func legacyError() throws {
        guard case .legacyError(let error) = HIDPPInbound(try framing.decode(hexBytes("10 03 8F 00 1A 08 00"))) else {
            Issue.record("expected a HID++ 1.0 error")
            return
        }
        #expect(error.deviceIndex == DeviceIndex(rawValue: 3))
        #expect(error.subID == 0x00 && error.address == 0x1A)
        #expect(error.code == .unknownDevice)
        #expect(HIDPP10ErrorCode.busy.isTransient)
        #expect(!HIDPP10ErrorCode.unknownDevice.isTransient)
    }

    @Test(
        "HID++ 1.0 register replies are not mistaken for feature messages",
        arguments: [UInt8(0x80), 0x81, 0x83, 0xB5, 0xFE]
    )
    func registerRange(subID: UInt8) throws {
        let report = try framing.decode([0x10, 0xFF, subID, 0x02, 0, 0, 0])
        #expect(HIDPPInbound(report) == .legacy(report))
    }

    @Test("other reports are HID++ 2.0 messages", arguments: [UInt8(0x00), 0x01, 0x40, 0x41, 0x7F])
    func messages(featureIndex: UInt8) throws {
        let inbound = HIDPPInbound(try framing.decode(hexBytes("11 FF \(String(featureIndex, radix: 16)) 3C 01 …")))
        guard case .message(let message) = inbound else {
            Issue.record("expected a message")
            return
        }
        #expect(message.featureIndex.rawValue == featureIndex)
        #expect(message.function.rawValue == 3)
        #expect(message.softwareID.rawValue == 0x0C)
        #expect(message.parameters.first == 0x01)
        #expect(message.parameters.count == 16)
    }

    @Test("error codes describe themselves")
    func descriptions() {
        #expect(HIDPP20ErrorCode.invalidFeatureIndex.description == "invalidFeatureIndex (0x06)")
        #expect(HIDPP20ErrorCode(rawValue: 0x42).description == "unrecognized (0x42)")
        #expect(HIDPP10ErrorCode.unknownDevice.description == "unknownDevice (0x08)")
    }
}
