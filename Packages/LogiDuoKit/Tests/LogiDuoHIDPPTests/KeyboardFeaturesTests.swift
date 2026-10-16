import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

/// Records every request and answers with the replies seen on an MX Keys.
private final class KeyboardResponder: @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private(set) var sent: [[UInt8]] = []

    var responder: FakeHIDPPTransport.Responder {
        { [self] request in
            lock.withLock { sent.append(request) }
            switch (request[2], request[3] >> 4) {
            case (0x09, 0): return [HIDPPTestTraffic.reply(to: request, parameters: [0x03, 0x01])]
            case (0x0C, 0): return [HIDPPTestTraffic.reply(to: request, parameters: [request[4], 0x01, 0x01])]
            case (0x0F, 0): return [HIDPPTestTraffic.reply(to: request, parameters: [0x1F])]
            case (0x0F, 1): return [HIDPPTestTraffic.reply(to: request, parameters: [0x21])]
            case (0x0B, 0): return [HIDPPTestTraffic.reply(to: request, parameters: [0x00, 0x05, 0x05])]
            default: return [HIDPPTestTraffic.reply(to: request)]
            }
        }
    }
}

@Suite("KeyboardFeatures (fake device only)", .timeLimit(.minutes(1)))
struct KeyboardFeaturesTests {
    private static func channel(_ responder: KeyboardResponder) async -> HIDPPChannel<ManualClock> {
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: responder.responder), clock: ManualClock())
        await channel.start()
        return channel
    }

    @Test("reads the current host, the function key mode for it, disabled keys and the backlight")
    func reads() async throws {
        let responder = KeyboardResponder()
        let channel = await Self.channel(responder)

        let host = try await KeyboardFeatures.currentHost(
            via: channel,
            index: FeatureIndex(rawValue: 0x09),
            deviceIndex: .direct
        )
        let mode = try await KeyboardFeatures.functionKeys(
            host: host,
            via: channel,
            index: FeatureIndex(rawValue: 0x0C),
            deviceIndex: .direct
        )
        let keys = try await KeyboardFeatures.disableKeys(
            via: channel,
            index: FeatureIndex(rawValue: 0x0F),
            deviceIndex: .direct
        )
        let backlight = try await KeyboardFeatures.backlight(
            via: channel,
            index: FeatureIndex(rawValue: 0x0B),
            deviceIndex: .direct
        )

        #expect(host == 1)
        #expect(mode == .special)
        #expect(keys.available.rawValue == 0x1F)
        #expect(keys.disabled == [.capsLock])
        #expect(backlight == .off)
        #expect(responder.sent[1][4] == 1, "the function key mode is read for the current host")
    }

    @Test("writes use the documented functions and bytes")
    func writes() async throws {
        let responder = KeyboardResponder()
        let channel = await Self.channel(responder)

        try await KeyboardFeatures.setFunctionKeys(
            .standard,
            host: 2,
            via: channel,
            index: FeatureIndex(rawValue: 0x0C),
            deviceIndex: .direct
        )
        try await KeyboardFeatures.setDisabledKeys(
            [.capsLock, .insert],
            via: channel,
            index: FeatureIndex(rawValue: 0x0F),
            deviceIndex: .direct
        )

        #expect(responder.sent[0][3] >> 4 == 1 && Array(responder.sent[0][4...5]) == [2, 0])
        #expect(responder.sent[1][3] >> 4 == 2 && responder.sent[1][4] == 0x09)
    }

    @Test("the read-only guard allows the keyboard getters and never the host switch or setters")
    func guardPolicy() {
        let allowed = ReadOnlyTransportGuard.allowedFunctions
        #expect(allowed[.changeHost] == [0])
        #expect(allowed[.fnInversionMultiHost] == [0])
        #expect(allowed[.disableKeys] == [0, 1])
        #expect(allowed[.backlight2] == [0])
    }
}
