import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

@Suite(
    "Hardware: pointer settings (read-only)",
    .enabled(if: logitechEndpointPresent),
    .serialized,
    .timeLimit(.minutes(2))
)
struct HardwarePointerTests {
    @Test("reads DPI and SmartShift through the read-only guard")
    func read() async throws {
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
            await Self.printResolution(name, channel)
            await Self.printSmartShift(name, channel)
            #expect(guarded.refusedReports == 0)
            await channel.close()
        }
    }

    private static func printResolution(_ name: String, _ channel: HIDPPChannel<ContinuousClock>) async {
        do {
            guard
                let dpi = try await RootFeature.location(
                    of: .adjustableDPI,
                    via: channel,
                    device: .direct,
                    timeout: .seconds(2)
                )
            else { return }
            let current = try await AdjustableDPIFeature.current(via: channel, index: dpi.index, deviceIndex: .direct)
            let range = try await AdjustableDPIFeature.supportedRange(
                via: channel,
                index: dpi.index,
                deviceIndex: .direct
            )
            print("[pointer] \(name) dpi=\(current) range=\(String(describing: range))")
        } catch {
            print("[pointer] \(name) dpi error \(error)")
        }
    }

    private static func printSmartShift(_ name: String, _ channel: HIDPPChannel<ContinuousClock>) async {
        for feature in [FeatureID.smartShift, .smartShiftEnhanced] {
            do {
                guard
                    let location = try await RootFeature.location(
                        of: feature,
                        via: channel,
                        device: .direct,
                        timeout: .seconds(2)
                    )
                else { continue }
                let mode = try await SmartShiftFeature.mode(
                    feature: feature,
                    via: channel,
                    index: location.index,
                    deviceIndex: .direct
                )
                print("[pointer] \(name) \(feature) v\(location.version) mode=\(mode)")
            } catch {
                print("[pointer] \(name) \(feature) error \(error)")
            }
        }
    }
}
