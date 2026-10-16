import Foundation
import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoPersistence
import LogiDuoSystem

/// Keeps the remapping engine on the profile for the frontmost application.
///
/// Recomputes the active profile whenever the configuration or the frontmost
/// application changes, and remembers whether remapping was on.
@MainActor
final class ProfileController {
    private let repository: ConfigurationRepository<ContinuousClock>
    private let coordinator: RemappingCoordinator
    private let observer: FrontmostApplicationObserver
    private let selector: ProfileSelector
    private var configuration = LogiDuoConfiguration.standard
    private var application: ApplicationIdentity?
    private var selection = ProfileSelection.defaultProfile
    private var tasks: [Task<Void, Never>] = []

    init(
        repository: ConfigurationRepository<ContinuousClock>,
        coordinator: RemappingCoordinator,
        observer: FrontmostApplicationObserver = FrontmostApplicationObserver(),
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.repository = repository
        self.coordinator = coordinator
        self.observer = observer
        let own =
            ownBundleIdentifier.flatMap(BundleIdentifier.init).map { [ApplicationMatcher.bundleIdentifier($0)] } ?? []
        selector = ProfileSelector(ignoredApplications: Set(own))
    }

    /// Starts following the configuration and the frontmost application.
    /// Restores remapping if it was on when the app last quit.
    func start() {
        guard tasks.isEmpty else { return }
        let repository = repository
        coordinator.enabledChanged = { enabled in
            Task { await repository.update { $0.general.remappingEnabled = enabled } }
        }
        observer.start()
        let identities = observer.identities
        tasks = [
            Task { [weak self] in
                var first = true
                for await configuration in await repository.updates() {
                    self?.configurationChanged(configuration, restoreRemapping: first)
                    first = false
                }
            },
            Task { [weak self] in
                for await identity in identities {
                    self?.applicationChanged(identity)
                }
            },
        ]
    }

    /// Stops following and saves pending changes.
    func stop() async {
        for task in tasks { task.cancel() }
        tasks = []
        observer.stop()
        await repository.flush()
    }

    private func configurationChanged(_ configuration: LogiDuoConfiguration, restoreRemapping: Bool) {
        self.configuration = configuration
        coordinator.applyScroll(configuration.scroll)
        update()
        if restoreRemapping, configuration.general.remappingEnabled, !coordinator.status.isEnabled {
            coordinator.setEnabled(true)
        }
    }

    private func applicationChanged(_ identity: ApplicationIdentity?) {
        application = identity
        update()
    }

    private func update() {
        let active = ActiveProfile.resolve(
            configuration,
            application: application,
            current: selection,
            selector: selector
        )
        selection = active.selection
        coordinator.apply(active)
    }
}
