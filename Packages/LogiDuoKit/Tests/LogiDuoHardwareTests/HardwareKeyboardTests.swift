import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

@Suite(
    "Hardware: keyboard features (read-only)",
    .enabled(if: logitechEndpointPresent),
    .serialized,
    .timeLimit(.minutes(2))
)
struct HardwareKeyboardTests {
    @Test("prints raw replies of the keyboard get functions")
    func raw() async throws {
        for descriptor in presentHIDPPEndpoints() {
            guard case .directDevice(_, let framing) = HIDInterfaceClassifier.role(of: descriptor) else { continue }
            let guarded = ReadOnlyTransportGuard(
                wrapping: try HIDDeviceMonitor.openSnapshotTransport(
                    registryID: descriptor.registryID,
                    framing: framing
                )
            )
            let channel = HIDPPChannel(transport: guarded, clock: ContinuousClock())
            await channel.start()
            let name = descriptor.productName ?? "?"
            let host = await Self.raw(channel, .changeHost, function: 0)
            print("[keyboard] \(name) changeHost fn0 → \(host ?? "-")")
            let current = await Self.currentHost(channel)
            let inversion = await Self.raw(channel, .fnInversionMultiHost, function: 0, [current])
            print("[keyboard] \(name) fnInversion fn0(\(current)) → \(inversion ?? "-")")
            print("[keyboard] \(name) backlight2 fn0 → \(await Self.raw(channel, .backlight2, function: 0) ?? "-")")
            print("[keyboard] \(name) disableKeys fn0 → \(await Self.raw(channel, .disableKeys, function: 0) ?? "-")")
            print("[keyboard] \(name) disableKeys fn1 → \(await Self.raw(channel, .disableKeys, function: 1) ?? "-")")
            #expect(guarded.refusedReports == 0)
            await channel.close()
        }
    }

    private static func currentHost(_ channel: HIDPPChannel<ContinuousClock>) async -> UInt8 {
        guard
            let location = try? await RootFeature.location(
                of: .changeHost,
                via: channel,
                device: .direct,
                timeout: .seconds(2)
            ),
            let function = FunctionID(rawValue: 0),
            let request = try? HIDPPRequest(
                deviceIndex: .direct,
                featureIndex: location.index,
                function: function,
                parameters: [],
                kind: .read
            ),
            let reply = try? await channel.send(request, timeout: .seconds(2))
        else { return 0 }
        return reply.parameters[1]
    }

    private static func raw(
        _ channel: HIDPPChannel<ContinuousClock>,
        _ feature: FeatureID,
        function: UInt8,
        _ parameters: [UInt8] = []
    ) async -> String? {
        guard
            let location = try? await RootFeature.location(
                of: feature,
                via: channel,
                device: .direct,
                timeout: .seconds(2)
            ),
            let functionID = FunctionID(rawValue: function),
            let request = try? HIDPPRequest(
                deviceIndex: .direct,
                featureIndex: location.index,
                function: functionID,
                parameters: parameters,
                kind: .read
            )
        else { return nil }
        do {
            let reply = try await channel.send(request, timeout: .seconds(2))
            return reply.parameters.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        } catch {
            return "error \(error)"
        }
    }
}
