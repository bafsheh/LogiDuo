import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("ReprogControlsFeature (read-only)", .timeLimit(.minutes(1)))
struct ReprogControlsFeatureTests {
    private func channel(_ device: FakeHIDPPDevice) async -> HIDPPChannel<ManualClock> {
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: device.responder), clock: ManualClock())
        await channel.start()
        return channel
    }

    @Test("V14: getCidInfo layout yields CID, task and 16-bit flags")
    func cidInfoVector() async throws {
        var device = FakeHIDPPDevice()
        device.controls = [[0x00, 0xD0, 0x00, 0xAD, 0x71, 0x05, 0x02, 0x0F, 0x01]]
        let controls = try await ReprogControlsFeature.controls(
            via: await channel(device),
            index: FeatureIndex(rawValue: 5),
            deviceIndex: .direct
        )
        #expect(controls.first?.control == 0x00D0)
        #expect(controls.first?.task == 0x00AD)
        #expect(controls.first?.flags.rawValue == 0x0171)
        #expect(controls.first?.flags.contains(.divertable) == true)
        #expect(controls.first?.flags.contains(.rawXY) == true)
    }

    @Test("V15: getCidReporting layout yields divert state and remap")
    func reportingVector() async throws {
        var device = FakeHIDPPDevice()
        device.reporting[0x00C3] = [0x00, 0xC3, 0x11, 0x00, 0x00, 0x00]
        let reporting = try await ReprogControlsFeature.reporting(
            of: 0x00C3,
            via: await channel(device),
            index: FeatureIndex(rawValue: 5),
            deviceIndex: .direct
        )
        #expect(reporting.flags == 0x0011)
        #expect(reporting.isDiverted && reporting.isRawXYDiverted)
        #expect(!reporting.isPersistentlyDiverted)
        #expect(reporting.remappedTo == 0x00C3)
        #expect(!reporting.isNative)
    }

    @Test("reads the whole control table with current reporting")
    func table() async throws {
        let controls = try await ReprogControlsFeature.controls(
            via: await channel(FakeHIDPPDevice()),
            index: FeatureIndex(rawValue: 5),
            deviceIndex: .direct
        )
        #expect(controls.map(\.control) == [0x0052, 0x00C3])
        #expect(controls.allSatisfy { $0.reporting?.isNative == true })
        #expect(controls[1].flags.contains([.divertable, .persistentlyDivertable, .rawXY]))
    }

    @Test("a persistent divert is recognised as not native")
    func persistentDivert() {
        let reporting = ControlReporting(control: 0x00C4, flags: 0x0004, remappedTo: 0x00C4)
        #expect(reporting.isPersistentlyDiverted && !reporting.isNative)
    }
}
