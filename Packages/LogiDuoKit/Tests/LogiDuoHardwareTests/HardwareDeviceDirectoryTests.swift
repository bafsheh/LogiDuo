import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

@Suite(
    "Hardware: device directory (read-only)",
    .enabled(if: logitechEndpointPresent),
    .serialized,
    .timeLimit(.minutes(2))
)
struct HardwareDeviceDirectoryTests {
    @Test("discovers, connects and reads every attached device through the read-only guard")
    func discover() async {
        let directory = DeviceDirectory(source: HIDDeviceMonitor(), clock: ContinuousClock(), authorization: .disabled)
        await directory.start()
        let expected = Set(presentHIDPPEndpoints().map(\.registryID)).count
        let watcher = Task {
            for await snapshots in await directory.snapshots()
            where snapshots.filter({ $0.link == .connected }).count >= expected {
                return snapshots
            }
            return []
        }
        let timeout = Task {
            try? await ContinuousClock().sleep(for: .seconds(20))
            watcher.cancel()
        }
        let snapshots = await watcher.value
        timeout.cancel()
        for device in snapshots {
            let battery = device.battery.map { "\($0.percentage ?? -1)%\($0.isCharging ? " charging" : "")" } ?? "?"
            print(
                "[directory] \(device.name) \(device.category) \(device.transport) \(device.link) battery=\(battery) "
                    + "fw=\(device.firmwareVersion ?? "?") features=0x\(String(device.features.rawValue, radix: 16))"
            )
        }
        #expect(!snapshots.isEmpty)
        await directory.stop()
    }
}
