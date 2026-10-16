import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoFeatures

private actor FakePermissions: PermissionsService {
    var opened: [PermissionKind] = []
    var requested: [PermissionKind] = []
    let values: [PermissionKind: PermissionStatus]

    init(_ values: [PermissionKind: PermissionStatus]) { self.values = values }

    func statuses() -> AsyncStream<[PermissionKind: PermissionStatus]> {
        let values = values
        return AsyncStream { continuation in
            continuation.yield(values)
            continuation.finish()
        }
    }

    func openSettings(for kind: PermissionKind) { opened.append(kind) }
    func requestAccess(for kind: PermissionKind) { requested.append(kind) }
}

private actor FakeLoginItem: LoginItemControlling {
    var enabled = false
    func isEnabled() -> Bool { enabled }
    func requiresApproval() -> Bool { false }
    func setEnabled(_ enabled: Bool) -> Bool {
        self.enabled = enabled
        return enabled
    }
}

@MainActor
@Suite("Shell view models")
struct ShellViewModelTests {
    @Test("permission statuses are shown and actions reach the service")
    func permissions() async {
        let service = FakePermissions([.accessibility: .denied, .inputMonitoring: .granted])
        let model = PermissionsViewModel(service: service)
        await model.observe()

        #expect(model.status(of: .accessibility) == .denied)
        #expect(!model.allGranted)
        await model.openSettings(for: .accessibility)
        await model.request(.inputMonitoring)
        #expect(await service.opened == [.accessibility])
        #expect(await service.requested == [.inputMonitoring])
    }

    @Test("settings mirror the login item and save the launch window preference")
    func settings() async {
        let loginItem = FakeLoginItem()
        let repository = FakeConfigurationRepository()
        let model = AppSettingsViewModel(loginItem: loginItem, repository: repository)
        await model.load()
        #expect(!model.launchAtLogin)

        await model.setLaunchAtLogin(true)
        await model.setShowsWindowAtLaunch(false)

        #expect(model.launchAtLogin)
        #expect(await loginItem.enabled)
        #expect(await !repository.current().general.showsWindowAtLaunch)
    }

    @Test("the menu summarises a device with its battery")
    func menuSummary() {
        let device = DeviceSnapshot(
            id: .fixture(1),
            name: "MX Master 3S",
            category: .mouse,
            transport: .bluetoothLowEnergy,
            link: .connected,
            battery: BatteryStatus(percentage: 65, isCharging: true)
        )
        #expect(MenuBarContentView.summary(of: device) == "MX Master 3S — 65% ⚡︎")
    }
}
