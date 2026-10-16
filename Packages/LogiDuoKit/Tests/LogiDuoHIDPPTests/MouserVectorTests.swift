import Foundation
import LogiDuoDomain
import LogiDuoHIDPP
import Testing

/// Byte-level vectors from the Mouser audit (V1–V57) that concern framing,
/// encoding and decoding. Feature semantics (DPI clamping, SmartShift rules,
/// wheel read-modify-write, catalog resolution) are evaluated with their
/// feature clients in later phases; this suite only proves the generic
/// codec produces and parses the exact bytes Mouser uses.
@Suite("Mouser protocol vectors")
struct MouserVectorTests {
    private let framing = HIDPPFraming.bluetoothLowEnergy
    private let mouserSoftwareID = SoftwareID(rawValue: 0x0A) ?? .notification

    private func function(_ value: UInt8) -> FunctionID {
        guard let function = FunctionID(rawValue: value) else { preconditionFailure("valid function") }
        return function
    }

    private func tx(
        _ device: DeviceIndex = .direct,
        feature: UInt8,
        function value: UInt8,
        _ parameters: [UInt8] = []
    ) throws -> [UInt8] {
        let request = try HIDPPRequest(
            deviceIndex: device,
            featureIndex: FeatureIndex(rawValue: feature),
            function: function(value),
            parameters: parameters,
            kind: .read
        )
        return try framing.encode(request.report(softwareID: mouserSoftwareID))
    }

    private func message(_ hex: String) throws -> HIDPPMessage {
        guard case .message(let message) = HIDPPInbound(try framing.decode(hexBytes(hex))) else {
            throw VectorFailure()
        }
        return message
    }

    private struct VectorFailure: Error {}

    @Test("V1 IRoot getFeature(0x1B04) on a direct device")
    func v01() throws {
        #expect(try tx(feature: 0x00, function: 0, [0x1B, 0x04, 0x00]) == hexBytes("11 FF 00 0A 1B 04 00 …"))
    }

    @Test("V2 the same request on Bolt slot 2")
    func v02() throws {
        let slot = DeviceIndex(receiverSlot: try #require(ReceiverSlot(rawValue: 2)))
        #expect(try tx(slot, feature: 0x00, function: 0, [0x1B, 0x04, 0x00]) == hexBytes("11 02 00 0A 1B 04 00 …"))
    }

    @Test("V3/V4 IRoot replies carry the feature index (0 means absent) in parameter 0")
    func v03v04() throws {
        let present = try message("11 FF 00 0A 09 00 04 …")
        let absent = try message("11 FF 00 0A 00 00 00 …")
        #expect(present.function == function(0) && present.softwareID == mouserSoftwareID)
        #expect(present.parameters[0] == 0x09)
        #expect(absent.parameters[0] == 0x00)
    }

    @Test("V5 a 0xFF error carries the code in parameter 1 and echoes the request")
    func v05() throws {
        guard case .featureError(let error) = HIDPPInbound(try framing.decode(hexBytes("11 FF FF 00 0A 02 …"))) else {
            Issue.record("expected an error report")
            return
        }
        #expect(error.code == .invalidArgument)
        #expect(error.featureIndex == .root && error.function == function(0) && error.softwareID == mouserSoftwareID)
    }

    @Test("V6 a reply with function+1 decodes as function 1 (LogiDuo does not accept it as fn0's reply)")
    func v06() throws {
        #expect(try message("11 FF 00 1A …").function == function(1))
    }

    @Test("V7 a reply with another software ID keeps that identifier")
    func v07() throws {
        #expect(try message("11 FF 00 05 …").softwareID.rawValue == 5)
    }

    @Test("V8 stripped report ID: decodes only at a full report length (Mouser accepted 5 bytes)")
    func v08() throws {
        let stripped = HIDPPFraming(outputTypes: [.long], inputIncludesReportID: false)
        let report = try stripped.decode(hexBytes("FF 09 00 00 C3 …", padTo: 19))
        guard case .message(let decoded) = HIDPPInbound(report) else {
            Issue.record("expected a message")
            return
        }
        #expect(decoded.deviceIndex == .direct && decoded.featureIndex.rawValue == 0x09)
        #expect(decoded.function == function(0) && decoded.softwareID == .notification)
        #expect(Array(decoded.parameters.prefix(2)) == [0x00, 0xC3])
    }

    @Test("V9 three bytes are rejected")
    func v09() {
        #expect(throws: HIDPPFrameError.lengthMismatch(.long, expected: 20, actual: 3)) {
            try framing.decode([0x11, 0xFF, 0x09])
        }
    }

    @Test("V10 parameters beyond the long payload are rejected instead of truncated")
    func v10() {
        #expect(throws: HIDPPFrameError.payloadTooLong(capacity: 16, actual: 17)) {
            try tx(feature: 0x00, function: 0, Array(repeating: 1, count: 17))
        }
    }

    @Test("V11/V12 DeviceName getCount and getName frames")
    func v11v12() throws {
        #expect(try tx(feature: 0x03, function: 0, [0, 0, 0]) == hexBytes("11 FF 03 0A 00 00 00 …"))
        #expect(try tx(feature: 0x03, function: 1, [0, 0, 0]) == hexBytes("11 FF 03 1A 00 00 00 …"))
        let chunk = try message("11 FF 03 1A 4D 58 20 4D 61 73 74 65 72 20 33 00 00 00 00 00")
        #expect(String(bytes: chunk.parameters.prefix { $0 != 0 }, encoding: .ascii) == "MX Master 3")
    }

    @Test("V13–V18 ReprogControlsV4 frames encode exactly")
    func v13to18() throws {
        #expect(try tx(feature: 0x09, function: 0) == hexBytes("11 FF 09 0A …"))
        #expect(try tx(feature: 0x09, function: 1, [0x02]) == hexBytes("11 FF 09 1A 02 …"))
        #expect(try tx(feature: 0x09, function: 2, [0x00, 0xC3]) == hexBytes("11 FF 09 2A 00 C3 …"))
        #expect(
            try tx(feature: 0x09, function: 3, [0x00, 0xC3, 0x33, 0, 0]) == hexBytes("11 FF 09 3A 00 C3 33 00 00 …")
        )
        #expect(
            try tx(feature: 0x09, function: 3, [0x00, 0xC4, 0x03, 0, 0]) == hexBytes("11 FF 09 3A 00 C4 03 00 00 …")
        )
        #expect(
            try tx(feature: 0x09, function: 3, [0x00, 0xC3, 0x22, 0, 0]) == hexBytes("11 FF 09 3A 00 C3 22 00 00 …")
        )
        let info = try message("11 FF 09 1A 00 D0 00 AD 71 05 02 0F 01 …")
        #expect(Array(info.parameters.prefix(9)) == [0x00, 0xD0, 0x00, 0xAD, 0x71, 0x05, 0x02, 0x0F, 0x01])
    }

    @Test("V21–V26 diverted-button and rawXY notifications decode with software ID 0")
    func v21to26() throws {
        let down = try message("11 FF 09 00 00 C3 00 00 …")
        let both = try message("11 FF 09 00 00 C3 00 C4 00 00 …")
        let move = try message("11 FF 09 10 FF FF 00 01 …")
        let extreme = try message("11 FF 09 10 80 00 7F FF …")
        #expect(down.softwareID.isNotification && down.function == function(0))
        #expect(Array(both.parameters.prefix(4)) == [0x00, 0xC3, 0x00, 0xC4])
        #expect(move.function == function(1))
        #expect(Int16(bitPattern: UInt16(move.parameters[0]) << 8 | UInt16(move.parameters[1])) == -1)
        #expect(Int16(bitPattern: UInt16(extreme.parameters[0]) << 8 | UInt16(extreme.parameters[1])) == .min)
        #expect(Int16(bitPattern: UInt16(extreme.parameters[2]) << 8 | UInt16(extreme.parameters[3])) == .max)
    }

    @Test("V28/V30 battery broadcast (sw 0) and solicited reply (sw 0x0A) are distinguishable")
    func v28v30() throws {
        #expect(try message("11 FF 08 00 55 08 01 00 …").softwareID.isNotification)
        let reply = try message("11 FF 08 1A 32 04 00 00 …")
        #expect(reply.softwareID == mouserSoftwareID && reply.parameters[0] == 0x32)
    }

    @Test("V32 and V34–V39 write and read frames encode exactly")
    func writeFrames() throws {
        #expect(try tx(feature: 0x0D, function: 3, [0x00, 0x06, 0x40]) == hexBytes("11 FF 0D 3A 00 06 40 …"))
        #expect(try tx(feature: 0x0D, function: 2, [0x00]) == hexBytes("11 FF 0D 2A 00 …"))
        #expect(try tx(feature: 0x0E, function: 2, [0x02, 0x1E, 0x32]) == hexBytes("11 FF 0E 2A 02 1E 32 …"))
        #expect(try tx(feature: 0x0E, function: 2, [0x01, 0x00, 0x3C]) == hexBytes("11 FF 0E 2A 01 00 3C …"))
        #expect(try tx(feature: 0x0E, function: 2, [0x02, 0xFF, 0x50]) == hexBytes("11 FF 0E 2A 02 FF 50 …"))
        #expect(try tx(feature: 0x0E, function: 1, [0x02, 0x1E, 0x00]) == hexBytes("11 FF 0E 1A 02 1E 00 …"))
        #expect(try tx(feature: 0x0E, function: 1) == hexBytes("11 FF 0E 1A …"))
        #expect(try tx(feature: 0x0E, function: 0) == hexBytes("11 FF 0E 0A …"))
    }

    @Test("V42–V45, V50–V52 wheel, haptic and force-sensing frames encode exactly")
    func wheelHapticFrames() throws {
        #expect(try tx(feature: 0x07, function: 1) == hexBytes("11 FF 07 1A …"))
        #expect(try tx(feature: 0x07, function: 2, [0x04]) == hexBytes("11 FF 07 2A 04 …"))
        #expect(try tx(feature: 0x08, function: 2, [0x00, 0x01]) == hexBytes("11 FF 08 2A 00 01 …"))
        #expect(try tx(feature: 0x07, function: 2, [0x02]) == hexBytes("11 FF 07 2A 02 …"))
        #expect(try tx(feature: 0x0B, function: 2, [0x01, 0x4B]) == hexBytes("11 FF 0B 2A 01 4B …"))
        #expect(try tx(feature: 0x0B, function: 4, [0x07]) == hexBytes("11 FF 0B 4A 07 …"))
        #expect(try tx(feature: 0x0C, function: 3, [0x00, 0x01, 0xF4]) == hexBytes("11 FF 0C 3A 00 01 F4 …"))
    }
}
