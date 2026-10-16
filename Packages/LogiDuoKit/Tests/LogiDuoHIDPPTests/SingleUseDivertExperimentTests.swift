import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

/// A switch shared between a device hook and a responder.
final class Flag: @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Holds a task so a device hook can cancel the run that triggered it.
final class TaskBox: @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private var task: Task<ExperimentReport, Never>?

    func set(_ task: Task<ExperimentReport, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}

@Suite("SingleUseDivertExperiment (fake device only)", .timeLimit(.minutes(1)))
struct SingleUseDivertExperimentTests {
    private typealias Rigs = ControlDivertTransactionTests
    static let unit = UnitID(rawValue: FakeReprogDevice.defaultUnit)
    static let operation = ExperimentOperation.mxMaster3SGestureDivertOnce

    struct Rig {
        let device: FakeReprogDevice
        let transport: FakeHIDPPTransport
        let store: InMemoryJournalStore
        let ledger: RestorationLedger
        let session: ExperimentSession
        let harness: SingleUseDivertExperiment<HIDPPChannel<ContinuousClock>>
        let recovery: DeviceRecovery<HIDPPChannel<ContinuousClock>>

        func token(unit: UnitID = SingleUseDivertExperimentTests.unit) async -> ExperimentAuthorization {
            await session.authorize(.mxMaster3SGestureDivertOnce, expectedUnit: unit)
        }

        func writes() -> [UInt8] { device.writeLog.map(\.1) }
    }

    static func rig(
        device: FakeReprogDevice = FakeReprogDevice(),
        store: InMemoryJournalStore = InMemoryJournalStore(),
        transport kind: TransportType = .bluetoothLowEnergy,
        target: ConfigurableDevice = Rigs.target(),
        session: ExperimentSession = ExperimentSession()
    ) async -> Rig {
        let transport = FakeHIDPPTransport(responder: device.responder)
        let channel = HIDPPChannel(transport: transport, clock: ContinuousClock())
        await channel.start()
        let ledger = RestorationLedger(store: store)
        _ = await ledger.load()
        let timeout = Duration.milliseconds(150)
        return Rig(
            device: device,
            transport: transport,
            store: store,
            ledger: ledger,
            session: session,
            harness: SingleUseDivertExperiment(
                connection: channel,
                target: target,
                transport: kind,
                ledger: ledger,
                session: session,
                timeout: timeout
            ),
            recovery: DeviceRecovery(
                connection: channel,
                target: target,
                ledger: ledger,
                authorization: .enabled,
                timeout: timeout
            )
        )
    }

    // MARK: Success and authorization

    @Test("one divert 0x03 and one restore 0x02, both verified; nothing left behind")
    func completes() async {
        let rig = await Self.rig()
        let report = await rig.harness.run(await rig.token())

        #expect(report.outcome == .completed)
        #expect(rig.writes() == [0x03, 0x02])
        #expect(rig.device.writeLog.allSatisfy { $0.0 == 0x00C3 })
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0)
        #expect(rig.store.persisted.isClean)
        #expect(rig.store.saves == 2)
        #expect(report.steps.first == .authorized)
        #expect(report.steps.last == .finalRead(ControlReporting(control: 0x00C3, flags: 0, remappedTo: 0x00C3)))
    }

    @Test("a token works once")
    func singleUse() async {
        let rig = await Self.rig()
        let token = await rig.token()
        #expect(await rig.harness.run(token).outcome == .completed)

        let again = await rig.harness.run(token)

        #expect(again.outcome == .aborted(.notAuthorized))
        #expect(again.steps.isEmpty)
        #expect(rig.writes() == [0x03, 0x02])
    }

    @Test("a token from another session is refused")
    func foreignSession() async {
        let rig = await Self.rig()
        let foreign = await ExperimentSession().authorize(Self.operation, expectedUnit: Self.unit)
        #expect(await rig.harness.run(foreign).outcome == .aborted(.notAuthorized))
        #expect(rig.writes().isEmpty)
    }

    @Test("repeated invocations with fresh tokens each complete and leave the device native")
    func repeated() async {
        let rig = await Self.rig()
        #expect(await rig.harness.run(await rig.token()).outcome == .completed)
        #expect(await rig.harness.run(await rig.token()).outcome == .completed)
        #expect(rig.writes() == [0x03, 0x02, 0x03, 0x02])
        #expect(rig.store.persisted.isClean)
    }

    // MARK: Preconditions

    @Test("only Bluetooth is accepted", arguments: [TransportType.usbWired, .receiver(.bolt)])
    func notBluetooth(kind: TransportType) async {
        let rig = await Self.rig(transport: kind)
        #expect(await rig.harness.run(await rig.token()).outcome == .aborted(.notBluetooth))
        #expect(rig.writes().isEmpty)
    }

    @Test("a token for another unit is refused before any request")
    func otherExpectedUnit() async {
        let rig = await Self.rig()
        #expect(
            await rig.harness.run(await rig.token(unit: UnitID(rawValue: 0x0BAD_0BAD))).outcome
                == .aborted(.identityMismatch)
        )
        #expect(rig.writes().isEmpty)
    }

    @Test("another model is refused even with a matching unit")
    func otherModel() async throws {
        let model = try #require(ModelID(rawValue: 0xB35B_408A_0000))
        let physical = PhysicalDeviceID(model: model, unit: Self.unit)
        let device = FakeReprogDevice()
        device.setIdentity(unit: FakeReprogDevice.defaultUnit, model: [0xB3, 0x5B, 0x40, 0x8A, 0x00, 0x00])
        let rig = await Self.rig(device: device, target: Rigs.target(physical: physical))
        #expect(await rig.harness.run(await rig.token()).outcome == .aborted(.identityMismatch))
        #expect(rig.writes().isEmpty)
    }

    @Test("a different unit answering on the connection is refused")
    func identitySwapped() async {
        let device = FakeReprogDevice()
        device.setIdentity(unit: 0x0BAD_0BAD, model: FakeReprogDevice.defaultModel)
        let rig = await Self.rig(device: device)
        #expect(await rig.harness.run(await rig.token()).outcome == .aborted(.identityMismatch))
        #expect(rig.writes().isEmpty)
    }

    @Test("a missing (silent) device aborts without a write")
    func missingDevice() async {
        let device = FakeReprogDevice()
        device.setFault(.unresponsive)
        let rig = await Self.rig(device: device)
        guard case .aborted = await rig.harness.run(await rig.token()).outcome else {
            Issue.record("must abort")
            return
        }
        #expect(rig.writes().isEmpty)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a corrupted journal or leftover records abort before anything is sent")
    func journalNotClean() async throws {
        let corrupted = InMemoryJournalStore()
        corrupted.corrupt()
        let first = await Self.rig(store: corrupted)
        #expect(await first.harness.run(await first.token()).outcome == .aborted(.journalNotClean))

        let leftover = InMemoryJournalStore()
        try await RestorationLedger(store: leftover).record(
            .wheelMode,
            on: .fixture(9),
            original: .byte(0)
        )
        let second = await Self.rig(store: leftover)
        #expect(await second.harness.run(await second.token()).outcome == .aborted(.journalNotClean))
        #expect(first.writes().isEmpty && second.writes().isEmpty)
    }

    @Test("a journal write failure aborts with nothing sent")
    func journalWriteFailure() async {
        let rig = await Self.rig()
        rig.store.failNextSaves(1)
        #expect(await rig.harness.run(await rig.token()).outcome == .aborted(.journalUnavailable))
        #expect(rig.writes().isEmpty)
        #expect(rig.store.persisted.isClean)
    }

    @Test(
        "an unexpected original state aborts with nothing sent",
        arguments: [(UInt8(0x01), UInt16(0)), (0x11, 0), (0x04, 0), (0x00, 0x0052)]
    )
    func unexpectedOriginal(flags: UInt8, remap: UInt16) async {
        let device = FakeReprogDevice()
        device.setReportingFlags(flags, of: 0x00C3)
        if remap != 0 { device.setRemap(remap, of: 0x00C3) }
        let rig = await Self.rig(device: device)
        guard case .aborted(.unexpectedOriginalState) = await rig.harness.run(await rig.token()).outcome else {
            Issue.record("must abort on a non-native original")
            return
        }
        #expect(rig.writes().isEmpty)
    }
}
