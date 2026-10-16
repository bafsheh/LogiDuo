public import LogiDuoDomain
public import Observation

/// Presentation state for the device dashboard.
@MainActor
@Observable
public final class DevicesViewModel {
    /// Known devices, in discovery order.
    public private(set) var devices: [DeviceSnapshot] = []

    private let service: any DeviceServicing
    private let router: AppRouter

    /// Creates a view model.
    public init(service: any DeviceServicing, router: AppRouter) {
        self.service = service
        self.router = router
    }

    /// The device shown in the detail area: the selected one, otherwise the first.
    public var selected: DeviceSnapshot? {
        if let id = router.selectedDevice, let device = devices.first(where: { $0.id == id }) { return device }
        return devices.first
    }

    /// Selects `device`.
    public func select(_ device: DeviceID) {
        router.selectDevice(device)
    }

    /// Re-reads every device.
    public func refresh() async {
        await service.refresh()
    }

    /// Follows device changes until the calling task is cancelled.
    public func observe() async {
        for await snapshots in await service.snapshots() {
            devices = snapshots
            router.reconcile(knownDevices: Set(snapshots.map(\.id)))
        }
    }
}
