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

    /// Device configuration writes. Disabled: no physical write has been verified yet,
    /// so recovery inspects devices through the read-only transport guard only.
    static let deviceWrites = DeviceWriteAuthorization.disabled

    init(router: AppRouter = AppRouter(), remapping: RemappingCoordinator? = nil) {
        self.router = router
        let coordinator = remapping ?? Self.makeRemapping()
        self.remapping = coordinator
        self.remappingModel = RemappingViewModel(service: coordinator)
        self.recoveryModel = RecoveryViewModel(
            service: Self.makeRecovery(),
            writesEnabled: Self.deviceWrites == .enabled
        )
    }

    /// Shows the recovery screen at launch when an earlier run left changes to undo.
    /// Nothing is restored or reset automatically.
    func checkRecoveryAtLaunch() async {
        await recoveryModel.refreshJournal()
        if recoveryModel.journal != .clean {
            router.show(.recovery)
        }
    }

    private static func makeRecovery() -> HIDPPRecoveryService {
        let ledger = RestorationLedger(store: FileRestorationJournalStore())
        return HIDPPRecoveryService(ledger: ledger) {
            await LiveRecoveryConnector.endpoints(ledger: ledger, authorization: deviceWrites)
        }
    }

    private static func makeRemapping() -> RemappingCoordinator {
        let checker = SystemPermissionChecker()
        let executor = SyntheticInputExecutor(poster: CoreGraphicsEventPoster())
        return RemappingCoordinator(
            engine: LiveInputEngine(executor: executor),
            checker: checker,
            permissionMonitor: PermissionMonitor(checker: checker, clock: ContinuousClock()),
            openURL: { NSWorkspace.shared.open($0) }
        )
    }
}
