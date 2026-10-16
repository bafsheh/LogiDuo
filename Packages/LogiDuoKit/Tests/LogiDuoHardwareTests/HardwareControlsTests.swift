import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

@Suite(
    "Hardware: reprogrammable controls (read-only)",
    .enabled(if: logitechEndpointPresent),
    .serialized,
    .timeLimit(.minutes(2))
)
struct HardwareControlsTests {
    @Test("reads every control's capabilities and current reporting through the read-only guard")
    func controls() async throws {
        for descriptor in presentHIDPPEndpoints() {
            guard case .directDevice(_, let framing) = HIDInterfaceClassifier.role(of: descriptor) else { continue }
            let raw = try HIDDeviceMonitor.openSnapshotTransport(registryID: descriptor.registryID, framing: framing)
            let guarded = ReadOnlyTransportGuard(wrapping: raw)
            let channel = HIDPPChannel(transport: guarded, clock: ContinuousClock())
            await channel.start()
            guard
                let location = try await RootFeature.location(
                    of: .reprogControlsV4,
                    via: channel,
                    device: .direct,
                    timeout: .seconds(2)
                )
            else {
                await channel.close()
                continue
            }
            let controls = try await ReprogControlsFeature.controls(
                via: channel,
                index: location.index,
                deviceIndex: .direct,
                timeout: .seconds(2)
            )
            let name = descriptor.productName ?? "?"
            print("[controls] \(name) ReprogControlsV4@\(location.index): \(controls.count) controls")
            for control in controls {
                print("[controls]   \(Self.describe(control))")
            }
            #expect(guarded.refusedReports == 0)
            await channel.close()
        }
    }

    private static func hex(_ value: UInt16) -> String { "0x" + String(value, radix: 16) }

    private static func describe(_ control: ReprogrammableControl) -> String {
        let state = control.reporting.map { reporting in
            "reporting=\(hex(reporting.flags)) remap=\(hex(reporting.remappedTo)) native=\(reporting.isNative)"
        }
        return
            "cid=\(hex(control.control)) task=\(hex(control.task)) flags=\(hex(control.flags.rawValue)) \(state ?? "?")"
    }
}
