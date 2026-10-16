import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

/// Whether physical-device tests were requested for this run.
let hardwareTestsEnabled = ProcessInfo.processInfo.environment["LOGIDUO_HARDWARE"] == "1"

/// HID++ endpoints present right now (read-only snapshot).
func presentHIDPPEndpoints() -> [HIDInterfaceDescriptor] {
    HIDDeviceMonitor.snapshot().filter { HIDInterfaceClassifier.role(of: $0).acceptsHIDPP }
}

/// Whether a Logitech HID++ endpoint is connected; Bluetooth devices disconnect when idle.
let logitechEndpointPresent = hardwareTestsEnabled && !presentHIDPPEndpoints().isEmpty

/// Collects `.added` events from a monitor until `settle` elapses. Read-only: nothing is opened.
func monitoredInterfaces(vendor: VendorID, settle: Duration = .milliseconds(750)) async -> [HIDInterfaceDescriptor] {
    let monitor = HIDDeviceMonitor(vendor: vendor)
    let collector = Task {
        var found: [HIDInterfaceDescriptor] = []
        for await event in monitor.events {
            if case .added(let descriptor) = event { found.append(descriptor) }
        }
        return found
    }
    try? await ContinuousClock().sleep(for: settle)
    monitor.stop()
    return await collector.value.sorted { $0.registryID < $1.registryID }
}

@Suite("Hardware: discovery plumbing (read-only)", .enabled(if: hardwareTestsEnabled), .timeLimit(.minutes(1)))
struct HardwareDiscoveryPlumbingTests {
    @Test("the monitor reports the same interfaces as a synchronous snapshot")
    func monitorMatchesSnapshot() async {
        // Apple's built-in HID services are always present; they are only enumerated, never opened.
        let apple = VendorID(rawValue: 0x05AC)
        let snapshot = HIDDeviceMonitor.snapshot(vendor: apple).map(\.registryID)
        let monitored = await monitoredInterfaces(vendor: apple).map(\.registryID)

        #expect(!snapshot.isEmpty)
        #expect(monitored == snapshot)
    }

    @Test("monitor start and stop cycles finish their event streams")
    func repeatedMonitors() async {
        for _ in 0..<20 {
            let monitor = HIDDeviceMonitor(vendor: VendorID(rawValue: 0x05AC))
            monitor.stop()
            for await _ in monitor.events {}
        }
    }
}

@Suite("Hardware: Logitech discovery (read-only)", .enabled(if: logitechEndpointPresent), .timeLimit(.minutes(1)))
struct HardwareLogitechDiscoveryTests {
    @Test("lists Logitech interfaces and their roles without opening them")
    func discovery() async {
        let interfaces = await monitoredInterfaces(vendor: .logitech)
        for descriptor in interfaces {
            print(
                "[hardware] \(descriptor.hardware) \(descriptor.productName ?? "?")",
                "transport=\(descriptor.transport ?? "?") usages=\(descriptor.usages)",
                "in=\(descriptor.maximumInputReportSize) out=\(descriptor.maximumOutputReportSize)",
                "role=\(HIDInterfaceClassifier.role(of: descriptor))"
            )
        }
        let endpoints = interfaces.filter { HIDInterfaceClassifier.role(of: $0).acceptsHIDPP }
        #expect(!endpoints.isEmpty)
    }
}
