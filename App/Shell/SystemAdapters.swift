import AppKit
import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoSystem

/// Permission statuses for the permission screen, from a polling monitor.
final class PermissionsAdapter: PermissionsService {
    private let checker: any PermissionChecking
    private let monitor: PermissionMonitor<ContinuousClock>

    init(checker: any PermissionChecking = SystemPermissionChecker()) {
        self.checker = checker
        monitor = PermissionMonitor(checker: checker, clock: ContinuousClock())
    }

    func statuses() -> AsyncStream<[PermissionKind: PermissionStatus]> {
        let monitor = monitor
        let (stream, continuation) = AsyncStream.makeStream(of: [PermissionKind: PermissionStatus].self)
        continuation.yield(monitor.snapshot())
        let running = Task {
            async let polling: Void = monitor.run()
            for await statuses in monitor.changes { continuation.yield(statuses) }
            await polling
        }
        continuation.onTermination = { _ in running.cancel() }
        return stream
    }

    func openSettings(for kind: PermissionKind) async {
        guard let url = PermissionSettingsLink.url(for: kind) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    func requestAccess(for kind: PermissionKind) {
        checker.requestPrompt(for: kind)
    }
}

/// Login item control for the Settings window.
struct LoginItemAdapter: LoginItemControlling {
    private let service = LoginItemService()

    func isEnabled() -> Bool { service.isEnabled }
    func setEnabled(_ enabled: Bool) -> Bool { service.setEnabled(enabled) }
}
