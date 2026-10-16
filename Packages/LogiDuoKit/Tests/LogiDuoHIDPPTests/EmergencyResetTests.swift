import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("DeviceRecovery: emergency reset scope and confirmation (fake device only)", .timeLimit(.minutes(1)))
struct EmergencyResetTests {
    private typealias Rigs = ControlDivertTransactionTests

    // MARK: Emergency reset scope

    @Test("the plan lists only managed controls and skips persistent and remapped ones")
    func planScope() async throws {
        let device = FakeReprogDevice()
        device.setReportingFlags(0x11, of: 0x00C3)
        device.setReportingFlags(0x05, of: 0x00C4)
        device.setReportingFlags(0x01, of: 0x0052)
        let rig = await RecoveryRigs.launch(device: device, store: InMemoryJournalStore())

        let plan = try await rig.recovery.planEmergencyReset()

        #expect(plan.items.map(\.control) == [0x00C3, 0x00C4])
        #expect(plan.items.map(\.disposition) == [.reset(.undivertWithRawXY), .skipped(.persistentlyDiverted)])
        #expect(device.writeLog.isEmpty)
        #expect(plan.device.physical == FakeReprogDevice.defaultPhysicalID)
    }

    @Test(
        "unexpected or foreign states are skipped, never written",
        arguments: [
            (UInt8(0x10), UInt16(0), EmergencyResetPlan.SkipReason.unexpectedState(0x10)),
            (0x01, 0x0052, .remapped(to: 0x0052)),
        ]
    )
    func foreignSkipped(flags: UInt8, remap: UInt16, reason: EmergencyResetPlan.SkipReason) async throws {
        let device = FakeReprogDevice()
        device.setReportingFlags(flags, of: 0x00C3)
        if remap != 0 { device.setRemap(remap, of: 0x00C3) }
        let rig = await RecoveryRigs.launch(device: device, store: InMemoryJournalStore())

        let plan = try await rig.recovery.planEmergencyReset()
        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )

        #expect(report.outcomes[0x00C3] == .skipped(reason))
        #expect(device.writeLog.isEmpty)
    }

    @Test("the reset writes only planned managed controls and leaves unrelated ones alone")
    func resetScope() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        device.setReportingFlags(0x01, of: 0x0052)
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let before = device.writeLog.count

        let plan = try await rig.recovery.planEmergencyReset()
        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )

        #expect(report.isComplete)
        #expect(device.writeLog.dropFirst(before).map(\.0) == [0x00C3, 0x00C4])
        #expect(device.reportingFlags(of: 0x0052) == 0x01)
        // Verified native, so the matching valid records are fulfilled.
        #expect(store.persisted.isClean)
    }

    @Test("partial emergency reset is reported per control")
    func partialReset() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        device.failWrites(to: [0x00C4])
        let rig = await RecoveryRigs.launch(device: device, store: store)

        let plan = try await rig.recovery.planEmergencyReset()
        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )

        #expect(report.outcomes == [0x00C3: .reset, 0x00C4: .failed(.request(.deviceError(.invalidArgument)))])
        #expect(!report.isComplete)
        #expect(store.persisted.entries.map(\.setting) == [Rigs.modeShiftSetting])
    }

    @Test("a control that changed after planning is not written")
    func stateChangedAfterPlanning() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let plan = try await rig.recovery.planEmergencyReset()
        device.setReportingFlags(0x00, of: 0x00C4)
        let before = device.writeLog.count

        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )

        #expect(report.outcomes[0x00C4] == .stateChanged)
        #expect(device.writeLog.dropFirst(before).map(\.0) == [0x00C3])
    }

    // MARK: Confirmation, authorization, concurrency

    @Test("declining the emergency reset writes nothing and keeps every record")
    func declined() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let before = device.writeLog.count

        let plan = try await rig.recovery.planEmergencyReset()
        _ = plan  // The person declines: no confirmation exists, so nothing can be performed.

        #expect(device.writeLog.count == before)
        #expect(store.persisted.entries.count == 2)
    }

    @Test("a confirmation of a different plan is refused")
    func confirmationOfOtherPlan() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let shown = try await rig.recovery.planEmergencyReset()
        let other = try await rig.recovery.planEmergencyReset()
        let before = device.writeLog.count

        let report = await rig.recovery.performEmergencyReset(
            other,
            confirmation: EmergencyResetConfirmation(userConfirmed: shown)
        )

        #expect(report.blocked == .notConfirmed)
        #expect(device.writeLog.count == before)
    }

    @Test("with writes disabled, recovery inspects but never writes")
    func writesDisabled() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store, authorization: .disabled)
        let before = device.writeLog.count

        #expect(await rig.recovery.exactRestore().failed.values.allSatisfy { $0 == .writesNotAuthorized })
        let plan = try await rig.recovery.planEmergencyReset()
        let report = await rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )

        #expect(report.blocked == .writesNotAuthorized)
        #expect(device.writeLog.count == before)
        #expect(store.persisted.entries.count == 2)
    }

    @Test("concurrent recovery attempts write each control once and agree on the result")
    func concurrentRecovery() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let before = device.writeLog.count

        async let first = rig.recovery.exactRestore()
        async let second = rig.recovery.exactRestore()
        let reports = await [first, second]

        #expect(reports.allSatisfy { $0.isComplete })
        #expect(reports.map(\.restored.count).sorted() == [0, 2])
        #expect(device.writeLog.count - before == 2)
        #expect(store.persisted.isClean)
    }

    @Test("an exact restore and an emergency reset racing each other never double-write")
    func restoreRacingReset() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let rig = await RecoveryRigs.launch(device: device, store: store)
        let plan = try await rig.recovery.planEmergencyReset()
        let before = device.writeLog.count

        async let exact = rig.recovery.exactRestore()
        async let reset = rig.recovery.performEmergencyReset(
            plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: plan)
        )
        let (exactReport, resetReport) = await (exact, reset)

        #expect(device.writeLog.count - before == 2)
        #expect(exactReport.isComplete)
        #expect(resetReport.outcomes.values.allSatisfy { $0 == .reset || $0 == .stateChanged })
        #expect(device.reportingFlags(of: 0x00C3) == 0 && device.reportingFlags(of: 0x00C4) == 0)
        #expect(store.persisted.isClean)
    }
}
