import AppKit
import LogiDuoFeatures
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

    init(router: AppRouter = AppRouter(), remapping: RemappingCoordinator? = nil) {
        self.router = router
        let coordinator = remapping ?? Self.makeRemapping()
        self.remapping = coordinator
        self.remappingModel = RemappingViewModel(service: coordinator)
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
