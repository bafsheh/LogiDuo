import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

/// Byte-exact checks of every setCidReporting (0x1B04 fn3) LogiDuo can emit.
///
/// Reference vectors: the flags byte layout of the x1b04 specification as
/// implemented independently by Solaar (`divert 0x01, persist 0x04, raw XY 0x10`,
/// each with its valid bit one above) and the bytes Mouser sends in the field
/// (`0x33`, `0x03`, `0x22`, `0x02`, request `[cid hi, cid lo, flags, 0, 0]`).
@Suite("ReportingCommand encoding (fake device only)", .timeLimit(.minutes(1)))
struct ReportingCommandTests {
    private static let gesture = ReprogrammableControl(
        control: 0x00C3,
        task: 0xA9,
        flags: [.divertable, .rawXY],
        reporting: nil
    )
    private static let modeShift = ReprogrammableControl(
        control: 0x00C4,
        task: 0x9D,
        flags: [.divertable],
        reporting: nil
    )

    private static func frame(
        _ command: ReportingCommand,
        control: UInt16,
        reply: (@Sendable ([UInt8]) -> [[UInt8]])? = nil
    ) async throws(DeviceConfigurationError) -> [UInt8] {
        let transport = FakeHIDPPTransport { sent in
            reply?(sent) ?? [HIDPPTestTraffic.reply(to: sent, parameters: [sent[4], sent[5], sent[6]])]
        }
        let channel = HIDPPChannel(transport: transport, clock: ManualClock())
        await channel.start()
        try await ReprogControlsFeature.send(
            command,
            to: control,
            via: channel,
            index: FeatureIndex(rawValue: 0x09),
            deviceIndex: .direct
        )
        return transport.sent.last ?? []
    }

    /// Everything but the software identifier nibble, which rotates.
    private static func masked(_ frame: [UInt8]) -> [UInt8] {
        frame.enumerated().map { index, byte in index == 3 ? byte & 0xF0 : byte }
    }

    @Test(
        "V16–V18: full long reports for every command",
        arguments: [
            (ReportingCommand.divertWithRawXY, UInt16(0x00C3), UInt8(0x33)),
            (.divertButtonOnly, 0x00C4, 0x03),
            (.undivertWithRawXY, 0x00C3, 0x22),
            (.undivertButtonOnly, 0x00C4, 0x02),
        ]
    )
    func vectors(command: ReportingCommand, control: UInt16, flags: UInt8) async throws {
        let sent = try await Self.frame(command, control: control)
        let expected: [UInt8] = [0x11, 0xFF, 0x09, 0x30, UInt8(control >> 8), UInt8(control & 0xFF), flags]
        #expect(Self.masked(sent) == expected + [UInt8](repeating: 0, count: 13))
        #expect(sent[3] & 0x0F != 0)
    }

    @Test("no command sets a persist, persist-valid or force-raw-XY bit")
    func neverPersistent() {
        for command in ReportingCommand.allCases {
            #expect(command.flagsByte & 0b1100_1100 == 0, "\(command)")
            // Every value bit is accompanied by its valid bit.
            #expect(command.flagsByte & 0x01 == 0 || command.flagsByte & 0x02 != 0)
            #expect(command.flagsByte & 0x10 == 0 || command.flagsByte & 0x20 != 0)
        }
    }

    @Test("the undivert for a state is the one that clears exactly that state")
    func undivertSelection() {
        #expect(
            ReportingCommand.undivert(from: ControlReporting(control: 0xC3, flags: 0x11, remappedTo: 0xC3))
                == .undivertWithRawXY
        )
        #expect(
            ReportingCommand.undivert(from: ControlReporting(control: 0xC4, flags: 0x01, remappedTo: 0xC4))
                == .undivertButtonOnly
        )
    }

    @Test(
        "verification requires the exact resulting state; unknown bits never pass",
        arguments: [UInt16(0x0003), 0x0005, 0x0015, 0x0040, 0x0100, 0x8001]
    )
    func strictVerification(flags: UInt16) {
        let reporting = ControlReporting(control: 0xC3, flags: flags, remappedTo: 0xC3)
        for command in ReportingCommand.allCases {
            #expect(!command.isSatisfied(by: reporting), "\(command) accepted \(flags)")
        }
        #expect(!reporting.isNative)
    }

    @Test("a remapped control is not native even with no reporting flags")
    func remapNotNative() {
        #expect(!ControlReporting(control: 0xC3, flags: 0, remappedTo: 0x52).isNative)
    }

    @Test("validation rejects raw XY without the capability and non-divertable controls")
    func validation() throws {
        #expect(throws: DeviceConfigurationError.unsupportedCombination(0x00C4)) {
            try ReportingCommand.divertWithRawXY.validate(for: Self.modeShift)
        }
        #expect(throws: DeviceConfigurationError.notDivertable(0x0050)) {
            try ReportingCommand.divertButtonOnly.validate(
                for: ReprogrammableControl(control: 0x50, task: 0x38, flags: [.mouseButton], reporting: nil)
            )
        }
        try ReportingCommand.divertWithRawXY.validate(for: Self.gesture)
    }

    @Test("a reply that echoes another control is rejected")
    func echoMismatch() async {
        await #expect(throws: DeviceConfigurationError.unexpectedResponse(0x00C3)) {
            _ = try await Self.frame(.divertWithRawXY, control: 0x00C3) { sent in
                [HIDPPTestTraffic.reply(to: sent, parameters: [0x00, 0xC4, sent[6]])]
            }
        }
    }

    @Test("a device error is surfaced, not treated as success")
    func deviceError() async {
        await #expect(throws: DeviceConfigurationError.request(.deviceError(.invalidArgument))) {
            _ = try await Self.frame(.divertWithRawXY, control: 0x00C3) { sent in
                [HIDPPTestTraffic.featureError(for: sent, code: 0x02)]
            }
        }
    }

    @Test("a getCidReporting reply for another control is rejected")
    func reportingEchoMismatch() async {
        var device = FakeHIDPPDevice()
        device.reporting[0x00C3] = [0x00, 0xC4, 0x00, 0x00, 0x00, 0x00]
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: device.responder), clock: ManualClock())
        await channel.start()
        await #expect(throws: HIDPPRequestError.self) {
            _ = try await ReprogControlsFeature.reporting(
                of: 0x00C3,
                via: channel,
                index: FeatureIndex(rawValue: 5),
                deviceIndex: .direct
            )
        }
    }
}
