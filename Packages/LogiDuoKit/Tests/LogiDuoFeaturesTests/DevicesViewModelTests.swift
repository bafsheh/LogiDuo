import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoTestSupport
import Testing

/// Publishes whatever the test sends.
final class FakeDeviceService: DeviceServicing, @unchecked Sendable {  // Invariant: continuation is thread-safe.
    private let stream: AsyncStream<[DeviceSnapshot]>
    private let sink: AsyncStream<[DeviceSnapshot]>.Continuation
    private(set) var refreshes = 0

    init() {
        (stream, sink) = AsyncStream.makeStream()
    }

    func send(_ snapshots: [DeviceSnapshot]) { sink.yield(snapshots) }
    func finish() { sink.finish() }
    func snapshots() -> AsyncStream<[DeviceSnapshot]> { stream }
    func refresh() { refreshes += 1 }
}

@MainActor
@Suite("DevicesViewModel")
struct DevicesViewModelTests {
    private static func device(_ index: Int, _ category: DeviceCategory = .mouse) -> DeviceSnapshot {
        DeviceSnapshot(
            id: .fixture(index),
            name: "Device \(index)",
            category: category,
            transport: .bluetoothLowEnergy,
            link: .connected
        )
    }

    @Test("shows published devices and defaults the detail to the first one")
    func publishes() async {
        let service = FakeDeviceService()
        let model = DevicesViewModel(service: service, router: AppRouter())
        service.send([Self.device(1), Self.device(2, .keyboard)])
        service.finish()

        await model.observe()

        #expect(model.devices.map(\.name) == ["Device 1", "Device 2"])
        #expect(model.selected?.id == .fixture(1))
    }

    @Test("selection follows the router and survives updates")
    func selection() async {
        let service = FakeDeviceService()
        let router = AppRouter()
        let model = DevicesViewModel(service: service, router: router)
        service.send([Self.device(1), Self.device(2)])
        model.select(.fixture(2))
        service.send([Self.device(1), Self.device(2)])
        service.finish()

        await model.observe()

        #expect(model.selected?.id == .fixture(2))
        #expect(router.selectedDevice == .fixture(2))
    }

    @Test("a selection of a device that disappeared falls back to the first device")
    func vanished() async {
        let service = FakeDeviceService()
        let router = AppRouter()
        let model = DevicesViewModel(service: service, router: router)
        router.selectDevice(.fixture(9))
        service.send([Self.device(1)])
        service.finish()

        await model.observe()

        #expect(router.selectedDevice == nil)
        #expect(model.selected?.id == .fixture(1))
    }

    @Test("refresh asks the service")
    func refresh() async {
        let service = FakeDeviceService()
        let model = DevicesViewModel(service: service, router: AppRouter())
        await model.refresh()
        #expect(service.refreshes == 1)
    }
}

@MainActor
@Suite("DevicesViewModel permissions")
struct DevicesViewModelPermissionTests {
    @Test("the Input Monitoring notice leads to the permission screen")
    func showPermissions() {
        let router = AppRouter()
        let model = DevicesViewModel(service: FakeDeviceService(), router: router)
        model.inputMonitoringMissing = true
        model.showPermissions()
        #expect(router.destination == .permissions)
    }
}
