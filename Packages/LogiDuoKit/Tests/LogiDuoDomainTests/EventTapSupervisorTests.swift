import LogiDuoDomain
import Testing

@Suite("EventTapSupervisor")
struct EventTapSupervisorTests {
    private func active() -> EventTapSupervisor {
        var supervisor = EventTapSupervisor()
        _ = supervisor.handle(.startRequested, at: .zero)
        _ = supervisor.handle(.tapInstalled, at: .zero)
        return supervisor
    }

    @Test("starting installs the tap and becomes active once installed")
    func start() {
        var supervisor = EventTapSupervisor()
        #expect(supervisor.handle(.startRequested, at: .zero) == [.installTap])
        #expect(supervisor.state == .installing)
        #expect(supervisor.handle(.tapInstalled, at: .zero).isEmpty)
        #expect(supervisor.state == .active)
    }

    @Test("a tap that cannot be installed suspends with a permission notice and retries when granted")
    func installationFailure() {
        var supervisor = EventTapSupervisor()
        _ = supervisor.handle(.startRequested, at: .zero)
        #expect(supervisor.handle(.tapInstallationFailed, at: .zero) == [.notify(.permissionMissing)])
        #expect(supervisor.state == .suspended(.permissionMissing))
        #expect(supervisor.handle(.permissionGranted, at: .seconds(5)) == [.installTap])
    }

    @Test("a timed-out tap is re-enabled after cancelling held presses")
    func timeoutRecovery() {
        var supervisor = active()
        #expect(supervisor.handle(.disabledByTimeout, at: .seconds(1)) == [.cancelHolds, .reenableTap])
        #expect(supervisor.state == .active)
    }

    @Test("repeated timeouts fail safe to native input and notify the user")
    func repeatedTimeouts() {
        var supervisor = active()
        _ = supervisor.handle(.disabledByTimeout, at: .seconds(1))
        _ = supervisor.handle(.disabledByTimeout, at: .seconds(4))
        #expect(
            supervisor.handle(.disabledByTimeout, at: .seconds(9)) == [
                .cancelHolds, .removeTap, .notify(.repeatedTimeouts),
            ]
        )
        #expect(supervisor.state == .suspended(.repeatedTimeouts))
        #expect(supervisor.handle(.disabledByTimeout, at: .seconds(10)).isEmpty)
    }

    @Test("timeouts spread beyond the window do not trip the fail-safe")
    func spreadTimeouts() {
        var supervisor = active()
        for second in [1, 12, 23, 34] {
            #expect(supervisor.handle(.disabledByTimeout, at: .seconds(second)) == [.cancelHolds, .reenableTap])
        }
        #expect(supervisor.state == .active)
    }

    @Test("the user can restart after a fail-safe suspension")
    func restartAfterFailSafe() {
        var supervisor = active()
        for second in [1, 2, 3] { _ = supervisor.handle(.disabledByTimeout, at: .seconds(second)) }
        #expect(supervisor.handle(.startRequested, at: .seconds(60)) == [.installTap])
        _ = supervisor.handle(.tapInstalled, at: .seconds(60))
        #expect(supervisor.handle(.disabledByTimeout, at: .seconds(61)) == [.cancelHolds, .reenableTap])
    }

    @Test("revoked permission cancels holds before removing the tap")
    func permissionRevoked() {
        var supervisor = active()
        #expect(
            supervisor.handle(.permissionRevoked, at: .zero) == [.cancelHolds, .removeTap, .notify(.permissionMissing)]
        )
        #expect(supervisor.state == .suspended(.permissionMissing))
    }

    @Test("disabling by user input re-enables without counting as a timeout")
    func userInput() {
        var supervisor = active()
        for second in 1...5 {
            #expect(supervisor.handle(.disabledByUserInput, at: .seconds(second)) == [.cancelHolds, .reenableTap])
        }
        #expect(supervisor.state == .active)
    }

    @Test("stopping always cancels holds before removing the tap")
    func stop() {
        var supervisor = active()
        #expect(supervisor.handle(.stopRequested, at: .zero) == [.cancelHolds, .removeTap])
        #expect(supervisor.state == .inactive)
        #expect(supervisor.handle(.stopRequested, at: .zero).isEmpty)
    }

    @Test(
        "signals that do not apply are ignored",
        arguments: [EventTapSignal.tapInstalled, .disabledByTimeout, .permissionGranted]
    )
    func ignored(signal: EventTapSignal) {
        var supervisor = EventTapSupervisor()
        #expect(supervisor.handle(signal, at: .zero).isEmpty)
        #expect(supervisor.state == .inactive)
    }

    @Test("LogiDuo recognises only its own synthetic marker")
    func marker() {
        #expect(SyntheticEventMarker.isLogiDuoEvent(userData: 0x4C47_444F))
        #expect(!SyntheticEventMarker.isLogiDuoEvent(userData: 0x4D4F_5554))
        #expect(!SyntheticEventMarker.isLogiDuoEvent(userData: 0))
    }
}
