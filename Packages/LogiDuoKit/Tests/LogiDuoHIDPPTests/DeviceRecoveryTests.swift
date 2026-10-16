import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("DeviceRecovery: exact restore and emergency reset (fake device only)", .timeLimit(.minutes(1)))
struct DeviceRecoveryTests {
    private typealias Rigs = ControlDivertTransactionTests

    // MARK: Crash points and startup

    @Test("crash after recording the original: the next launch restores without writing")
    func crashAfterRecord() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await RecoveryRigs.launch(device: device, store: store).ledger.record(
            Rigs.gestureSetting,
            on: .fixture(1),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )

        let next = await RecoveryRigs.launch(device: device, store: store)
        #expect(next.loaded == .pending(entries: 1))
        #expect(await next.recovery.exactRestore().isComplete)
        #expect(device.writeLog.isEmpty)
        #expect(store.persisted.isClean)
    }

    @Test("crash after diverting: startup blocks new configuration until the exact restore ran")
    func crashAfterDivertAndStartup() async throws {
        let (device, store) = try await RecoveryRigs.diverted()

        let next = await RecoveryRigs.launch(device: device, store: store)
        #expect(next.loaded == .pending(entries: 2))
        await #expect(throws: DeviceConfigurationError.recoveryPending) {
            try await next.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        }
        let report = await next.recovery.exactRestore()

        #expect(report.isComplete && report.restored.count == 2)
        #expect(device.reportingFlags(of: 0x00C3) == 0 && device.reportingFlags(of: 0x00C4) == 0)
        #expect(Array(device.writeLog.map(\.1).suffix(2)) == [0x22, 0x02])
        try await next.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
    }

    @Test("failure during diversion keeps the record; exact restore then verifies native and clears it")
    func failureDuringDivert() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        device.failWrites(to: [0x00C3])
        await #expect(throws: DeviceConfigurationError.request(.deviceError(.invalidArgument))) {
            try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        }
        #expect(store.persisted.entries.count == 1)

        device.failWrites(to: [])
        #expect(await rig.recovery.exactRestore().isComplete)
        #expect(store.persisted.isClean)
    }

    @Test("failure during restoration of one of several controls: partial, and only that record stays")
    func failureDuringRestoration() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        device.failWrites(to: [0x00C4])

        let report = await RecoveryRigs.launch(device: device, store: store).recovery.exactRestore()

        #expect(!report.isComplete)
        #expect(report.restored == [Rigs.gestureSetting])
        #expect(report.failed[Rigs.modeShiftSetting] == .request(.deviceError(.invalidArgument)))
        #expect(store.persisted.entries.map(\.setting) == [Rigs.modeShiftSetting])
        #expect(store.persisted.entries.first?.failedAttempts == 1)
    }

    @Test("an acknowledged write without a state change is never reported as restored")
    func acknowledgedWithoutChange() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        device.setFault(.ignoresWrites)
        let rig = await RecoveryRigs.launch(device: device, store: store)

        let exact = await rig.recovery.exactRestore()
        #expect(exact.restored.isEmpty)
        #expect(exact.failed[Rigs.gestureSetting] == .restorationIncomplete(0x00C3))

        let plan = try await rig.recovery.planEmergencyReset()
        let reset = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )
        #expect(reset.outcomes[0x00C3] == .failed(.restorationIncomplete(0x00C3)))
        #expect(!reset.isComplete)
        #expect(store.persisted.entries.count == 2)
    }

    // MARK: Identity

    @Test("reconnecting under the same identity restores everything")
    func reconnectSameIdentity() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        #expect(await RecoveryRigs.launch(device: device, store: store).recovery.exactRestore().isComplete)
        #expect(store.persisted.isClean)
    }

    @Test("reconnecting over another transport (same unit, other device index) restores under the same records")
    func reconnectOtherTransport() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        var target = Rigs.target()
        target = ConfigurableDevice(
            identity: target.identity,
            physical: target.physical,
            deviceIndex: DeviceIndex(rawValue: 0x02),
            reprogIndex: target.reprogIndex,
            informationIndex: target.informationIndex
        )
        #expect(
            await RecoveryRigs.launch(device: device, store: store, target: target).recovery.exactRestore().isComplete
        )
        #expect(store.persisted.isClean)
    }

    @Test("a changed logical identity neither inherits nor loses records; emergency reset still works")
    func reconnectChangedIdentity() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store, target: Rigs.target(identity: .fixture(2)))

        #expect(await rig.recovery.exactRestore().restored.isEmpty)
        let plan = try await rig.recovery.planEmergencyReset()
        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )

        #expect(report.outcomes == [0x00C3: .reset, 0x00C4: .reset])
        #expect(store.persisted.pending(for: store.key(for: .fixture(1))).count == 2)
    }

    @Test("an unknown physical identity blocks every recovery write and keeps every record")
    func unknownIdentity() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        device.hideIdentity()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let writes = device.writeLog.count

        #expect(await rig.recovery.exactRestore().failed.values.allSatisfy { $0 == .identityMismatch })
        await #expect(throws: DeviceConfigurationError.identityMismatch) {
            _ = try await rig.recovery.planEmergencyReset()
        }
        #expect(device.writeLog.count == writes)
        #expect(store.persisted.entries.count == 2)
    }

    @Test("regression: a plan made for one unit cannot be performed after another unit took its place")
    func unitSwappedAfterPlanning() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let plan = try await rig.recovery.planEmergencyReset()
        device.setIdentity(unit: 0x0BAD_0BAD, model: FakeReprogDevice.defaultModel)
        let writes = device.writeLog.count

        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )

        #expect(report.blocked == .identityMismatch)
        #expect(device.writeLog.count == writes)
    }

    // MARK: Corrupted journal

    @Test("a corrupted journal is never acted on automatically and never discarded")
    func corruptedJournal() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        store.corrupt()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let writes = device.writeLog.count

        #expect(rig.loaded == .corrupted)
        let exact = await rig.recovery.exactRestore()
        guard case .corrupted = exact.journalError else {
            Issue.record("exact restore must refuse a corrupted journal")
            return
        }
        await #expect(throws: DeviceConfigurationError.self) {
            try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        }
        #expect(device.writeLog.count == writes)

        let plan = try await rig.recovery.planEmergencyReset()
        #expect(plan.journalCorrupted)
        #expect(plan.changes.map(\.control) == [0x00C3, 0x00C4])
        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )
        #expect(report.isComplete)
        // Still blocked until the person explicitly acknowledges the notice.
        #expect(await rig.ledger.corruption != nil)
        await rig.ledger.acknowledgeCorruption()
        try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
    }

    @Test("regression: after a corrupted load nothing new is recorded or diverted, even on a native control")
    func corruptedJournalBlocksNewDiverts() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        store.corrupt()
        let rig = await RecoveryRigs.launch(device: device, store: store)

        await #expect(throws: DeviceConfigurationError.journalUnavailable(.corrupted(quarantinedAt: rig.quarantine))) {
            try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        }
        #expect(device.writeLog.isEmpty)
        #expect(store.saves == 0)
    }
}
