public import LogiDuoDomain
public import Observation

/// Presentation state for the device dashboard.
@MainActor
@Observable
public final class DevicesViewModel {
    /// Known devices, in discovery order.
    public private(set) var devices: [DeviceSnapshot] = []
    /// Saved per-device preferences.
    public private(set) var preferences: [DeviceID: DeviceSettings] = [:]
    /// The outcome of the last setting change, per device.
    public private(set) var lastResult: [DeviceID: DeviceSettingResult] = [:]
    /// Whether this version may change device settings.
    public let writesEnabled: Bool

    private let service: any DeviceServicing
    private let settings: (any DeviceSettingsServicing)?
    private let repository: (any ConfigurationRepositing)?
    private let router: AppRouter

    /// Creates a view model.
    public init(
        service: any DeviceServicing,
        router: AppRouter,
        settings: (any DeviceSettingsServicing)? = nil,
        repository: (any ConfigurationRepositing)? = nil,
        writesEnabled: Bool = false
    ) {
        self.service = service
        self.router = router
        self.settings = settings
        self.repository = repository
        self.writesEnabled = writesEnabled
    }

    /// The saved preferences of `device`.
    public func preference(for device: DeviceID) -> DeviceSettings {
        preferences[device] ?? .unchanged
    }

    /// Saves and applies a pointer resolution.
    public func setResolution(_ dpi: Int, for device: DeviceID) async {
        await savePreference(device) { $0.resolution = dpi }
        lastResult[device] = await settings?.setResolution(dpi, on: device) ?? .unavailable
    }

    /// Saves and applies a SmartShift mode.
    public func setSmartShift(_ mode: SmartShiftMode, for device: DeviceID) async {
        await savePreference(device) { $0.smartShift = mode }
        lastResult[device] = await settings?.setSmartShift(mode, on: device) ?? .unavailable
    }

    /// Adds a resolution to the cycle presets (sorted, without duplicates).
    public func addPreset(_ dpi: Int, for device: DeviceID) async {
        await savePreference(device) { settings in
            settings = DeviceSettings(
                resolution: settings.resolution,
                resolutionPresets: (settings.resolutionPresets + [dpi]).sorted(),
                smartShift: settings.smartShift
            )
        }
    }

    /// Removes a resolution from the cycle presets.
    public func removePreset(_ dpi: Int, for device: DeviceID) async {
        await savePreference(device) { $0.resolutionPresets.removeAll { $0 == dpi } }
    }

    private func savePreference(_ device: DeviceID, _ change: @escaping @Sendable (inout DeviceSettings) -> Void) async
    {
        var updated = preference(for: device)
        change(&updated)
        preferences[device] = updated
        await repository?.update { configuration in
            var settings = configuration.settings(for: device)
            change(&settings)
            configuration.devices[device] = settings
        }
    }

    /// Follows saved preferences until the calling task is cancelled.
    public func observePreferences() async {
        guard let repository else { return }
        for await configuration in await repository.updates() {
            preferences = configuration.devices
        }
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
