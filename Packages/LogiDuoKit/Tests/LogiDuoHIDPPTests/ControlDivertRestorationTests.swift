import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("ControlDivertTransaction restoration (fake device only)", .timeLimit(.minutes(1)))
struct ControlDivertRestorationTests {
    private typealias Rigs = ControlDivertTransactionTests

    @Test("normal shutdown restores every control, verifies, and clears the journal")
    func shutdownRestore() async throws {
        let rig = await Rigs.rig()
        try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        try await rig.transaction.divert(Rigs.modeShift, with: .divertButtonOnly)

        let report = await rig.transaction.restoreAll()

        #expect(report.isComplete)
        #expect(report.restored == [Rigs.gestureSetting, Rigs.modeShiftSetting])
        #expect(rig.device.writeLog.map(\.1) == [0x33, 0x03, 0x22, 0x02])
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0 && rig.device.reportingFlags(of: 0x00C4) == 0)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a restore that times out keeps the entry; the next connection completes it")
    func timeoutThenReconnect() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let first = await Rigs.rig(device: device, store: store)
        try await first.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        device.setFault(.unresponsive)

        let restoring = Task { await first.transaction.restoreAll() }
        #expect(await eventually { first.clock.sleeperCount > 0 })
        first.clock.advance(by: .seconds(1))
        let failed = await restoring.value

        #expect(failed.failed == [Rigs.gestureSetting: .identityMismatch])
        #expect(store.persisted.entries.count == 1)
        #expect(device.reportingFlags(of: 0x00C3) == 0x11)

        device.setFault(.none)
        let reconnected = await Rigs.rig(device: device, store: store)
        #expect(await reconnected.transaction.restoreAll().isComplete)
        #expect(store.persisted.isClean)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
    }

    @Test("regression: a restore the device acknowledges but does not apply stays pending")
    func unappliedRestore() async throws {
        let rig = await Rigs.rig()
        try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        rig.device.setFault(.ignoresWrites)

        let report = await rig.transaction.restoreAll()

        #expect(report.failed[Rigs.gestureSetting] == .restorationIncomplete(0x00C3))
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0x11)
        #expect(rig.store.persisted.entries.first?.failedAttempts == 1)
    }

    @Test("a control that became persistently diverted or remapped is not restored blindly")
    func foreignChangeWhilePending() async throws {
        let rig = await Rigs.rig()
        try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        rig.device.setRemap(0x0052, of: 0x00C3)

        let report = await rig.transaction.restoreAll()

        #expect(report.failed[Rigs.gestureSetting] == .foreignState(0x00C3))
        #expect(rig.device.writeLog.count == 1)
        #expect(rig.store.persisted.entries.count == 1)
    }

    @Test("next-launch recovery: after a crash, a new run restores before anything else")
    func nextLaunchRecovery() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await Rigs.rig(device: device, store: store).transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        // The process dies here: no restore runs.

        let relaunched = await Rigs.rig(device: device, store: store)
        #expect(await relaunched.ledger.load() == .pending(entries: 1))
        #expect(await relaunched.transaction.restoreAll().isComplete)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(store.persisted.isClean)
    }

    @Test("an interrupted write (recorded, never sent) is recovered without any write")
    func interruptedWrite() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let rig = await Rigs.rig(device: device, store: store)
        try await rig.ledger.record(
            Rigs.gestureSetting,
            on: .fixture(1),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )

        let recovered = await Rigs.rig(device: device, store: store)
        #expect(await recovered.transaction.restoreAll().isComplete)
        #expect(device.writeLog.isEmpty)
    }

    @Test("partial restoration is reported as incomplete and keeps only the unfinished entry")
    func partialRestoration() async throws {
        let rig = await Rigs.rig()
        try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        try await rig.ledger.record(.wheelMode, on: .fixture(1), original: .byte(0x02))

        let report = await rig.transaction.restoreAll()

        #expect(!report.isComplete)
        #expect(report.restored == [Rigs.gestureSetting])
        #expect(report.failed[.wheelMode] == .unsupportedSetting(.wheelMode))
        #expect(rig.store.persisted.entries.map(\.setting) == [.wheelMode])
    }

    @Test("restoring is idempotent")
    func idempotent() async throws {
        let rig = await Rigs.rig()
        try await rig.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        _ = await rig.transaction.restoreAll()
        let writes = rig.device.writeLog.count

        let again = await rig.transaction.restoreAll()

        #expect(again.isComplete && again.restored.isEmpty)
        #expect(rig.device.writeLog.count == writes)
    }

    @Test("a device power-cycled while LogiDuo was gone is recovered without a write")
    func powerCycled() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await Rigs.rig(device: device, store: store).transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        device.powerCycle()

        #expect(await Rigs.rig(device: device, store: store).transaction.restoreAll().isComplete)
        #expect(device.writeLog.count == 1)
        #expect(store.persisted.isClean)
    }

    @Test("a corrupted journal is reported, not mistaken for a clean state")
    func corruptedJournal() async {
        let store = InMemoryJournalStore()
        store.corrupt()
        #expect(await RestorationLedger(store: store).load() == .corrupted)
    }

    @Test("reconnecting over a different transport (same unit) restores under the same physical identity")
    func transportChange() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await Rigs.rig(device: device, store: store).transaction.divert(Rigs.gesture, with: .divertWithRawXY)

        let overBolt = await Rigs.rig(device: device, store: store)
        #expect(await overBolt.transaction.restoreAll().isComplete)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
    }

    @Test("a device that comes back with a different identity does not inherit or lose recovery records")
    func identityChange() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await Rigs.rig(device: device, store: store).transaction.divert(Rigs.gesture, with: .divertWithRawXY)

        let renamed = await Rigs.rig(device: device, store: store, target: Rigs.target(identity: .fixture(2)))
        #expect(await renamed.transaction.restoreAll().restored.isEmpty)
        #expect(store.persisted.pending(for: store.key(for: .fixture(1))).count == 1)
    }
}
