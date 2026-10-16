import AppKit
import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoSystem

/// Connects the remapping control to the live input engine and the permission service.
///
/// Safety rules:
/// * Remapping starts disabled and no event tap exists until the user enables it.
/// * Enabling never installs the tap without Accessibility permission; macOS is
///   asked at most once per launch, then the user is told where to grant it.
/// * Disabling, quitting, permission loss and tap failures release held input and
///   remove the tap, so input is native again.
@MainActor
final class RemappingCoordinator: RemappingService {
    private(set) var status = RemappingStatus.off
    let statusUpdates: AsyncStream<RemappingStatus>

    private let engine: LiveInputEngine
    private let checker: any PermissionChecking
    private let permissionMonitor: PermissionMonitor<ContinuousClock>
    private let openURL: (URL) -> Void
    private let statusSink: AsyncStream<RemappingStatus>.Continuation
    private var policy = PermissionRequestPolicy()
    private var profile = ActiveProfile.none
    /// Called with the enabled flag whenever the person turns remapping on or off.
    var enabledChanged: (Bool) -> Void = { _ in }
    private var tasks: [Task<Void, Never>] = []

    init(
        engine: LiveInputEngine,
        checker: any PermissionChecking,
        permissionMonitor: PermissionMonitor<ContinuousClock>,
        openURL: @escaping (URL) -> Void
    ) {
        self.engine = engine
        self.checker = checker
        self.permissionMonitor = permissionMonitor
        self.openURL = openURL
        (statusUpdates, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    /// Starts observing permissions and the engine. Call once at launch.
    func activate() {
        guard tasks.isEmpty else { return }
        let monitor = permissionMonitor
        let engine = self.engine
        tasks = [
            Task { await monitor.run() },
            Task { [weak self] in
                for await statuses in monitor.changes {
                    self?.permissionsChanged(statuses)
                }
            },
            Task { [weak self] in
                for await state in engine.states {
                    self?.engineStateChanged(state)
                }
            },
            Task { [weak self] in
                let sleeps = NSWorkspace.shared.notificationCenter.notifications(
                    named: NSWorkspace.willSleepNotification
                )
                for await _ in sleeps.map({ _ in () }) {
                    self?.hostWillSleep()
                }
            },
            Task { [weak self] in
                let clock = ContinuousClock()
                var deadline = clock.now + .seconds(1)
                while !Task.isCancelled {
                    try? await clock.sleep(until: deadline, tolerance: nil)
                    deadline += .seconds(1)
                    if self?.status.isIntercepting == true { engine.expireStalePresses() }
                }
            },
        ]
    }

    /// Restores native input and stops background work (on quit).
    func shutdown() {
        disable()
        for task in tasks { task.cancel() }
        tasks = []
    }

    /// Releases held synthetic input before the Mac sleeps (internal for tests).
    func hostWillSleep() {
        engine.cancelHeldInput()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { enable() } else { disable() }
        enabledChanged(enabled)
    }

    /// Applies the profile in effect (from the configuration and the frontmost application).
    func apply(_ profile: ActiveProfile) {
        guard profile != self.profile else { return }
        self.profile = profile
        status.activeProfileName = status.preset == .configured ? profile.name : nil
        if status.isEnabled, status.preset == .configured { engine.updateMappings(resolved(.configured)) }
        publish()
    }

    func select(_ preset: ValidationPreset) {
        status.preset = preset
        status.activeProfileName = preset == .configured ? profile.name : nil
        if status.isEnabled { engine.updateMappings(resolved(preset)) }
        publish()
    }

    func openPermissionSettings() {
        if let url = PermissionSettingsLink.url(for: .accessibility) { openURL(url) }
    }

    // MARK: - Transitions

    private func enable() {
        status.isEnabled = true
        let actions = policy.actions(
            forEnabling: .remapping,
            statuses: [.accessibility: checker.status(of: .accessibility)]
        )
        if actions.contains(.none) {
            startEngine()
        } else {
            if actions.contains(.prompt(.accessibility)) { checker.requestPrompt(for: .accessibility) }
            status.notice = .accessibilityRequired
            status.isIntercepting = false
        }
        publish()
    }

    private func disable() {
        engine.updateMappings(.passThrough)
        engine.stop()
        status = RemappingStatus(
            isEnabled: false,
            isIntercepting: false,
            preset: status.preset,
            notice: nil,
            activeProfileName: status.activeProfileName
        )
        publish()
    }

    private func startEngine() {
        engine.start()
        engine.updateMappings(resolved(status.preset))
        engineStateChanged(engine.state)
    }

    /// Applies a permission snapshot (from the monitor; internal for tests).
    func permissionsChanged(_ statuses: [PermissionKind: PermissionStatus]) {
        let granted = statuses[.accessibility] == .granted
        if status.isIntercepting || engine.state != .inactive {
            engine.permissionChanged(granted: granted)
        }
        if granted, status.isEnabled, status.notice == .accessibilityRequired, engine.state == .inactive {
            startEngine()
        }
        engineStateChanged(engine.state)
    }

    private func engineStateChanged(_ state: EventTapState) {
        guard status.isEnabled else { return }
        switch state {
        case .active:
            status.isIntercepting = true
            status.notice = nil
        case .suspended(.permissionMissing):
            status.isIntercepting = false
            status.notice = .accessibilityRequired
        case .suspended(.repeatedTimeouts):
            status.isIntercepting = false
            status.notice = .stoppedAfterRepeatedTimeouts
        case .inactive, .installing:
            status.isIntercepting = false
        }
        publish()
    }

    private func resolved(_ preset: ValidationPreset) -> ResolvedMappings {
        // System-reported buttons only until device diversion is authorized: no capabilities are used.
        let mappings = preset == .configured ? profile.mappings : preset.mappings
        return MappingResolver.resolve(mappings, capabilities: .undiscovered, mode: .enabled)
    }

    private func publish() {
        statusSink.yield(status)
    }
}
