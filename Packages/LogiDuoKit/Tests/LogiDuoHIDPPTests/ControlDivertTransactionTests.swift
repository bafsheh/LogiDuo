import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("ControlDivertTransaction and recovery (fake device only)", .timeLimit(.minutes(1)))
struct ControlDivertTransactionTests {
    private static let gesture = ReprogrammableControl(
        control: 0x00C3,
        task: 0xA9,
        flags: [.divertable, .rawXY],
        reporting: nil
    )
    private static let modeShift = ReprogrammableControl(
        control: 0x00C4,
        task: 0x9D,
        flags: [.divertable],
        reporting: nil
    )
    private static let left = ReprogrammableControl(control: 0x0050, task: 0x38, flags: [.mouseButton], reporting: nil)
    private static let divertWithRawXY = ReportingChange(divert: true, rawXY: true)

    private struct Rig {
        let device: FakeReprogDevice
        let store: InMemoryJournalStore
        let ledger: RestorationLedger
        let transaction: ControlDivertTransaction<HIDPPChannel<ManualClock>>
        let clock: ManualClock
    }

    private static func rig(
        device: FakeReprogDevice = FakeReprogDevice(),
        store: InMemoryJournalStore = InMemoryJournalStore(),
        identity: DeviceID = .fixture(1)
    ) async -> Rig {
        let clock = ManualClock()
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: device.responder), clock: clock)
        await channel.start()
        let ledger = RestorationLedger(store: store)
        _ = await ledger.load()
        let transaction = ControlDivertTransaction(
            device: channel,
            identity: identity,
            featureIndex: FeatureIndex(rawValue: 1),
            deviceIndex: .direct,
            ledger: ledger,
            timeout: .seconds(1)
        )
        return Rig(device: device, store: store, ledger: ledger, transaction: transaction, clock: clock)
    }

    @Test("diverting records the original durably first, writes once, and verifies by reading back")
    func divert() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)

        #expect(rig.device.reportingFlags(of: 0x00C3) == 0x11)
        #expect(rig.device.writeLog.map(\.1) == [0x33])
        #expect(
            rig.store.persisted.pending(for: rig.store.key(for: .fixture(1))).map(\.original)
                == [.controlReporting(diverted: false, rawXYDiverted: false)]
        )
    }

    @Test("a control the firmware does not allow to divert is never written")
    func notDivertable() async {
        let rig = await Self.rig()
        await #expect(throws: DeviceConfigurationError.notDivertable(0x0050)) {
            try await rig.transaction.divert(Self.left, change: ReportingChange(divert: true, rawXY: false))
        }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a control already diverted by something else is not taken over")
    func foreignState() async {
        let device = FakeReprogDevice()
        device.setReportingFlags(0x01, of: 0x00C3)
        let rig = await Self.rig(device: device)
        await #expect(throws: DeviceConfigurationError.foreignState(0x00C3)) {
            try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        }
        #expect(rig.device.writeLog.isEmpty)
    }

    @Test("if the recovery record cannot be stored, the device is not changed")
    func journalUnavailable() async {
        let rig = await Self.rig()
        rig.store.failNextSaves(1)
        await #expect(throws: DeviceConfigurationError.journalUnavailable(.fileSystem("injected"))) {
            try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0)
    }

    @Test("a device that acknowledges but ignores the write fails verification and is left native")
    func verificationFailure() async {
        let device = FakeReprogDevice()
        device.setFault(.ignoresWrites)
        let rig = await Self.rig(device: device)
        await #expect(throws: DeviceConfigurationError.verificationFailed(0x00C3)) {
            try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        }
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0)
        #expect(rig.store.persisted.isClean)
    }

    @Test("normal shutdown restores every control, verifies, and clears the journal")
    func shutdownRestore() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        try await rig.transaction.divert(Self.modeShift, change: ReportingChange(divert: true, rawXY: false))

        let report = await rig.transaction.restoreAll()

        #expect(report.isComplete)
        #expect(report.restored.count == 2)
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0 && rig.device.reportingFlags(of: 0x00C4) == 0)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a restore that times out keeps the entry; the next connection completes it")
    func timeoutThenReconnect() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let first = await Self.rig(device: device, store: store)
        try await first.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        device.setFault(.unresponsive)

        let restoring = Task { await first.transaction.restoreAll() }
        #expect(await eventually { first.clock.sleeperCount > 0 })
        first.clock.advance(by: .seconds(1))
        let failed = await restoring.value

        #expect(!failed.isComplete)
        #expect(store.persisted.entries.first?.failedAttempts == 1)
        #expect(device.reportingFlags(of: 0x00C3) == 0x11)

        device.setFault(.none)
        let reconnected = await Self.rig(device: device, store: store)
        #expect(await reconnected.transaction.restoreAll().isComplete)
        #expect(store.persisted.isClean)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
    }

    @Test("regression: a restore the device acknowledges but does not apply stays pending")
    func unappliedRestore() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        rig.device.setFault(.ignoresWrites)

        let report = await rig.transaction.restoreAll()

        #expect(report.failed[.controlReporting(DeviceControlID(rawValue: 0x00C3))] == .restorationIncomplete(0x00C3))
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0x11)
        #expect(rig.store.persisted.entries.first?.failedAttempts == 1)
    }

    @Test("next-launch recovery: after a crash, a new run restores before anything else")
    func nextLaunchRecovery() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await Self.rig(device: device, store: store).transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        // The process dies here: no restore runs.

        let relaunched = await Self.rig(device: device, store: store)
        #expect(await relaunched.ledger.load() == .pending(entries: 1))
        #expect(await relaunched.transaction.restoreAll().isComplete)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(store.persisted.isClean)
    }

    @Test("an interrupted write (recorded, never sent) is recovered harmlessly")
    func interruptedWrite() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let rig = await Self.rig(device: device, store: store)
        try await rig.ledger.record(
            .controlReporting(DeviceControlID(rawValue: 0x00C3)),
            on: .fixture(1),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )

        let recovered = await Self.rig(device: device, store: store)
        #expect(await recovered.transaction.restoreAll().isComplete)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
    }

    @Test("partial restoration is reported as incomplete and keeps only the unfinished entry")
    func partialRestoration() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        try await rig.ledger.record(.wheelMode, on: .fixture(1), original: .byte(0x02))

        let report = await rig.transaction.restoreAll()

        #expect(!report.isComplete)
        #expect(report.restored == [.controlReporting(DeviceControlID(rawValue: 0x00C3))])
        #expect(report.failed[.wheelMode] == .unsupportedSetting(.wheelMode))
        #expect(rig.store.persisted.entries.map(\.setting) == [.wheelMode])
    }

    @Test("restoring is idempotent")
    func idempotent() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        _ = await rig.transaction.restoreAll()
        let writes = rig.device.writeLog.count

        let again = await rig.transaction.restoreAll()

        #expect(again.isComplete && again.restored.isEmpty)
        #expect(rig.device.writeLog.count == writes)
    }

    @Test("a device power-cycled while LogiDuo was gone is recovered without harm")
    func powerCycled() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await Self.rig(device: device, store: store).transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        device.powerCycle()

        #expect(await Self.rig(device: device, store: store).transaction.restoreAll().isComplete)
        #expect(store.persisted.isClean)
    }

    @Test("a corrupted journal is reported, not mistaken for a clean state")
    func corruptedJournal() async {
        let store = InMemoryJournalStore()
        store.corrupt()
        #expect(await RestorationLedger(store: store).load() == .corrupted)
    }

    @Test("a device that comes back with a different identity does not inherit or lose recovery records")
    func identityChange() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        try await Self.rig(device: device, store: store).transaction.divert(Self.gesture, change: Self.divertWithRawXY)

        let renamed = await Self.rig(device: device, store: store, identity: .fixture(2))
        #expect(await renamed.transaction.restoreAll().restored.isEmpty)
        #expect(store.persisted.pending(for: store.key(for: .fixture(1))).count == 1)
    }

    @Test("persistent divert bits are never written")
    func neverPersistent() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, change: Self.divertWithRawXY)
        try await rig.transaction.divert(Self.modeShift, change: ReportingChange(divert: true, rawXY: false))
        _ = await rig.transaction.restoreAll()

        #expect(rig.device.writeLog.allSatisfy { $0.1 & 0x0C == 0 })
        #expect(ReportingChange(divert: false, rawXY: true) == .native)
    }
}
