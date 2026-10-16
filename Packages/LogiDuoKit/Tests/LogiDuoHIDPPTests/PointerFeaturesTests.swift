import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("Pointer features: AdjustableDPI and SmartShift (fake device only)", .timeLimit(.minutes(1)))
struct PointerFeaturesTests {
    @Test("a stepped DPI list (low, 0xE000|step, high) becomes a range")
    func steppedRange() {
        let range = AdjustableDPIFeature.parseRange([0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0x00, 0x00])
        #expect(range == ResolutionRange(minimum: 200, maximum: 8000, step: 50))
    }

    @Test("an evenly spaced DPI list becomes a range; an uneven one does not")
    func listRange() {
        #expect(
            AdjustableDPIFeature.parseRange([0x01, 0x90, 0x03, 0x20, 0x04, 0xB0, 0, 0])
                == ResolutionRange(minimum: 400, maximum: 1200, step: 400)
        )
        #expect(AdjustableDPIFeature.parseRange([0x01, 0x90, 0x03, 0x20, 0x07, 0xD0, 0, 0]) == nil)
        #expect(AdjustableDPIFeature.parseRange([0, 0]) == nil)
    }

    @Test("SmartShift bytes decode as Mouser and Options+ use them")
    func smartShiftDecode() {
        #expect(SmartShiftFeature.decode(mode: 0x01, autoDisengage: 0x19) == .freeSpin)
        #expect(SmartShiftFeature.decode(mode: 0x02, autoDisengage: 0x19) == .automatic(sensitivity: 25))
        #expect(SmartShiftFeature.decode(mode: 0x02, autoDisengage: 0xFF) == .ratchet)
        #expect(SmartShiftFeature.decode(mode: 0x02, autoDisengage: 0x00) == .ratchet)
    }

    @Test("SmartShift modes encode to fixed bytes, thresholds clamped to 1–50")
    func smartShiftEncode() {
        #expect(SmartShiftFeature.encode(.freeSpin) == [0x01, 0x00])
        #expect(SmartShiftFeature.encode(.ratchet) == [0x02, 0xFF])
        #expect(SmartShiftFeature.encode(.automatic(sensitivity: 99)) == [0x02, 50])
        #expect(SmartShiftFeature.encode(.automatic(sensitivity: 0)) == [0x02, 1])
    }

    @Test("the read-only guard allows reading DPI and SmartShift and refuses setting them")
    func guardPolicy() {
        let allowed = ReadOnlyTransportGuard.allowedFunctions
        #expect(allowed[.adjustableDPI] == [0, 1, 2])
        #expect(allowed[.smartShift]?.contains(1) == false)
        #expect(allowed[.smartShiftEnhanced]?.contains(2) == false)
        #expect(allowed[.hiResWheel]?.contains(2) == false)
        #expect(allowed[.thumbwheel]?.contains(2) == false)
    }

    @Test("reads use the documented functions and parse the reply")
    func reads() async throws {
        let transport = FakeHIDPPTransport { sent in
            switch sent[3] >> 4 {
            case 1: [HIDPPTestTraffic.reply(to: sent, parameters: [0x00, 0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0, 0])]
            case 2: [HIDPPTestTraffic.reply(to: sent, parameters: [0x00, 0x06, 0x40, 0x03, 0xE8])]
            default: [HIDPPTestTraffic.featureError(for: sent, code: 0x07)]
            }
        }
        let channel = HIDPPChannel(transport: transport, clock: ManualClock())
        await channel.start()
        let index = FeatureIndex(rawValue: 0x0D)

        #expect(try await AdjustableDPIFeature.current(via: channel, index: index, deviceIndex: .direct) == 1600)
        #expect(
            try await AdjustableDPIFeature.supportedRange(via: channel, index: index, deviceIndex: .direct)
                == ResolutionRange(minimum: 200, maximum: 8000, step: 50)
        )
    }
}
