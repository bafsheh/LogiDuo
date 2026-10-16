import AppKit
import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoHID
import LogiDuoHIDPP
import LogiDuoPersistence
import LogiDuoSystem

/// Builds the application's object graph.
///
/// This is the only place where concrete infrastructure is chosen and wired
/// into the presentation layer. Everything is created once, explicitly, and
/// handed down through initializers — there are no service locators.
@MainActor
final class AppCompositionRoot {
    /// Main-window navigation state, shared by the window and the menu bar.
    let router: AppRouter
    /// Live remapping, off at launch.
    let remapping: RemappingCoordinator
    /// The menu-bar remapping control.
    let remappingModel: RemappingViewModel
    /// The device recovery screen.
    let recoveryModel: RecoveryViewModel
    /// Every attached Logitech device (read-only while writes are disabled).
    let devices: DeviceDirectory<ContinuousClock>
    /// The device dashboard.
    let devicesModel: DevicesViewModel
    /// The configuration (mappings, profiles, preferences), saved debounced.
    let configuration: ConfigurationRepository<ContinuousClock>
    /// Follows the frontmost application's profile.
    let profiles: ProfileController
    /// The mapping editor.
    let mappingsModel: MappingEditorViewModel
    /// Application profiles.
    let profilesModel: ProfilesViewModel
    /// Scroll preferences.
    let scrollModel: ScrollSettingsViewModel
    /// The permission overview.
    let permissionsModel = PermissionsViewModel(service: PermissionsAdapter())
    /// The Settings window.
    let settingsModel: AppSettingsViewModel
    /// Importing Mouser settings.
    let importModel: MouserImportViewModel
    /// Performs device actions (cycle pointer speed, toggle SmartShift).
    let deviceActions: DeviceActionController
    private let executor: SyntheticInputExecutor

    /// Device configuration writes. Disabled: no physical write has been verified yet,
    /// so recovery inspects devices through the read-only transport guard only.
    static let deviceWrites = DeviceWriteAuthorization.disabled

    init(router: AppRouter = AppRouter(), remapping: RemappingCoordinator? = nil) {
        self.router = router
        let executor = SyntheticInputExecutor(poster: CoreGraphicsEventPoster())
        self.executor = executor
        let coordinator = remapping ?? Self.makeRemapping(executor: executor)
        self.remapping = coordinator
        let repository = ConfigurationRepository(store: FileConfigurationStore(), clock: ContinuousClock())
        self.configuration = repository
        self.profiles = ProfileController(repository: repository, coordinator: coordinator)
        self.mappingsModel = MappingEditorViewModel(repository: repository)
        self.profilesModel = ProfilesViewModel(repository: repository)
        self.scrollModel = ScrollSettingsViewModel(repository: repository)
        self.settingsModel = AppSettingsViewModel(loginItem: LoginItemAdapter(), repository: repository)
        self.remappingModel = RemappingViewModel(service: coordinator)
        // One ledger for the journal file: two would each save a stale copy over the other's records.
        let ledger = RestorationLedger(store: FileRestorationJournalStore())
        self.recoveryModel = RecoveryViewModel(
            service: Self.makeRecovery(ledger: ledger),
            writesEnabled: Self.deviceWrites == .enabled
        )
        let directory = DeviceDirectory(
            source: HIDDeviceMonitor(),
            clock: ContinuousClock(),
            authorization: Self.deviceWrites,
            ledger: ledger
        )
        self.devices = directory
        self.devicesModel = DevicesViewModel(
            service: directory,
            router: router,
            settings: directory,
            repository: repository,
            writesEnabled: Self.deviceWrites == .enabled
        )
        self.deviceActions = DeviceActionController(directory: directory, repository: repository)
        let importer = MouserImportService(
            repository: repository,
            backup: FileConfigurationStore(fileURL: MouserImportService<ContinuousClock>.defaultBackupURL()),
            mice: { await directory.knownDevices().filter { $0.category == .mouse }.map(\.id) },
            resolveApplication: InstalledApplicationResolver.resolve
        )
        self.importModel = MouserImportViewModel(service: importer)
    }

    /// The main window's screens.
    var screens: RootScreens {
        RootScreens(
            devices: devicesModel,
            mappings: mappingsModel,
            scrolling: scrollModel,
            profiles: profilesModel,
            permissions: permissionsModel,
            recovery: recoveryModel
        )
    }

    /// Warns about other device software.
    private let conflicts = ConflictingSoftwareMonitor()

    /// Starts device discovery and forwards Mac sleep and wake to device connections.
    func startDevices() {
        conflicts.start()
        let model = devicesModel
        let running = conflicts.running
        Task { for await software in running { model.conflicts = software } }
        let directory = devices
        let repository = configuration
        let actions = deviceActions
        executor.handleDeviceActions { action in
            Task { await actions.perform(action) }
        }
        let coordinator = remapping
        // One ordered consumer: separate Tasks per change could apply an older set last.
        let (diversions, latest) = AsyncStream.makeStream(
            of: Set<MouseButton>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        coordinator.diversionChanged = { buttons in latest.yield(buttons) }
        Task { for await buttons in diversions { await directory.setDiversion(buttons) } }
        Task { await directory.useDeviceInput { event in await MainActor.run { coordinator.deviceInput(event) } } }
        Task {
            await directory.usePreferences { device in await repository.current().settings(for: device) }
            await directory.start()
            await actions.follow()
        }
        Task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification)
                .map({ _ in () })
            {
                await directory.hostWillSleep()
            }
        }
        Task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
                .map({ _ in () })
            {
                await directory.hostDidWake()
            }
        }
    }

    /// Shows the recovery screen at launch when an earlier run left changes to undo.
    /// Nothing is restored or reset automatically.
    func checkRecoveryAtLaunch() async {
        await recoveryModel.refreshJournal()
        if recoveryModel.journal != .clean {
            router.show(.recovery)
        }
    }

    private static func makeRecovery(ledger: RestorationLedger) -> HIDPPRecoveryService {
        return HIDPPRecoveryService(ledger: ledger) {
            await LiveRecoveryConnector.endpoints(ledger: ledger, authorization: deviceWrites)
        }
    }

    private static func makeRemapping(executor: SyntheticInputExecutor) -> RemappingCoordinator {
        let checker = SystemPermissionChecker()
        return RemappingCoordinator(
            engine: LiveInputEngine(executor: executor),
            checker: checker,
            permissionMonitor: PermissionMonitor(checker: checker, clock: ContinuousClock()),
            openURL: { NSWorkspace.shared.open($0) }
        )
    }
}
