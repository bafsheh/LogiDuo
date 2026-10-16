import LogiDuoDomain
import LogiDuoHID
import LogiDuoPersistence

/// Performs device actions triggered by mappings on the connected mouse.
///
/// * Cycle pointer speed: the next of the mouse's resolution presets.
/// * Toggle SmartShift: automatic ↔ ratchet.
/// * Toggle scroll mode: ratchet ↔ free spin.
///
/// Each change is saved as the mouse's preference and applied through the device
/// directory, which refuses it while device writes are disabled.
actor DeviceActionController {
    private let directory: DeviceDirectory<ContinuousClock>
    private let repository: ConfigurationRepository<ContinuousClock>
    private var mouse: DeviceSnapshot?

    init(directory: DeviceDirectory<ContinuousClock>, repository: ConfigurationRepository<ContinuousClock>) {
        self.directory = directory
        self.repository = repository
    }

    /// Follows the connected devices (call once).
    func follow() async {
        for await snapshots in await directory.snapshots() {
            mouse = snapshots.first { $0.category == .mouse && $0.link == .connected }
        }
    }

    /// Performs `action` on the connected mouse, if any.
    func perform(_ action: DeviceAction) async {
        guard let mouse else { return }
        let preferences = await repository.current().settings(for: mouse.id)
        switch action {
        case .cycleResolutionPresets:
            let current = preferences.resolution ?? mouse.resolution?.current
            guard let next = preferences.nextResolutionPreset(after: current) else { return }
            await save(mouse.id) { $0.resolution = next }
            _ = await directory.setResolution(next, on: mouse.id)
        case .toggleSmartShift:
            let mode: SmartShiftMode =
                if case .automatic = preferences.smartShift ?? mouse.smartShift { .ratchet } else {
                    .automatic(sensitivity: 10)
                }
            await apply(mode, on: mouse.id)
        case .toggleScrollMode:
            let mode: SmartShiftMode = (preferences.smartShift ?? mouse.smartShift) == .freeSpin ? .ratchet : .freeSpin
            await apply(mode, on: mouse.id)
        }
    }

    private func apply(_ mode: SmartShiftMode, on device: DeviceID) async {
        await save(device) { $0.smartShift = mode }
        _ = await directory.setSmartShift(mode, on: device)
    }

    private func save(_ device: DeviceID, _ change: @escaping @Sendable (inout DeviceSettings) -> Void) async {
        await repository.update { configuration in
            var settings = configuration.settings(for: device)
            change(&settings)
            configuration.devices[device] = settings
        }
    }
}
