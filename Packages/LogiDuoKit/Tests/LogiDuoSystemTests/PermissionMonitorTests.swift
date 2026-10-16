import Foundation
import LogiDuoDomain
import LogiDuoSystem
import LogiDuoTestSupport
import Testing

final class FakePermissionChecker: PermissionChecking, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var statuses: [PermissionKind: PermissionStatus]
    private(set) var prompts: [PermissionKind] = []

    init(_ statuses: [PermissionKind: PermissionStatus]) {
        self.statuses = statuses
    }

    func set(_ kind: PermissionKind, _ status: PermissionStatus) { lock.withLock { statuses[kind] = status } }
    func status(of kind: PermissionKind) -> PermissionStatus { lock.withLock { statuses[kind] ?? .notDetermined } }
    func requestPrompt(for kind: PermissionKind) { lock.withLock { prompts.append(kind) } }
}

@Suite("PermissionMonitor", .timeLimit(.minutes(1)))
struct PermissionMonitorTests {
    @Test("publishes the initial status and then only changes, without prompting")
    func publishesChanges() async {
        let checker = FakePermissionChecker([.accessibility: .granted, .inputMonitoring: .granted])
        let clock = ManualClock()
        let monitor = PermissionMonitor(checker: checker, clock: clock)
        var changes = monitor.changes.makeAsyncIterator()
        let polling = Task { await monitor.run() }

        #expect(await changes.next()?[.accessibility] == .granted)
        clock.advance(by: .seconds(2))
        checker.set(.accessibility, .denied)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(2))
        #expect(await changes.next()?[.accessibility] == .denied)
        checker.set(.accessibility, .granted)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(2))
        #expect(await changes.next()?[.accessibility] == .granted)

        polling.cancel()
        _ = await polling.value
        #expect(checker.prompts.isEmpty)
    }

    @Test("settings links point at the right privacy panes")
    func links() {
        #expect(
            PermissionSettingsLink.url(for: .accessibility)?.absoluteString.hasSuffix("Privacy_Accessibility") == true
        )
        #expect(
            PermissionSettingsLink.url(for: .inputMonitoring)?.absoluteString.hasSuffix("Privacy_ListenEvent") == true
        )
        #expect(PermissionSettingsLink.instructions(for: .accessibility).contains("Accessibility"))
    }
}
