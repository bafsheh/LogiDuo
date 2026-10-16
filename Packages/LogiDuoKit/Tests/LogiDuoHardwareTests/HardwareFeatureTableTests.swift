import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

@Suite(
    "Hardware: feature tables (read-only)",
    .enabled(if: logitechEndpointPresent),
    .serialized,
    .timeLimit(.minutes(2))
)
struct HardwareFeatureTableTests {
    @Test("lists every feature of every attached device")
    func table() async throws {
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
            let inventory = try await DeviceInventoryReader.read(
                via: channel,
                deviceIndex: .direct,
                timeout: .seconds(2)
            )
            let features = inventory.features.map { "\($0.feature)@\($0.index.rawValue) v\($0.version)" }
            print("[features] \(descriptor.productName ?? "?"): " + features.joined(separator: ", "))
            #expect(guarded.refusedReports == 0)
            await channel.close()
        }
    }
}
