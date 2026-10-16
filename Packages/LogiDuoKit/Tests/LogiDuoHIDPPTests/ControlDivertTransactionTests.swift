import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("ControlDivertTransaction (fake device only)", .timeLimit(.minutes(1)))
struct ControlDivertTransactionTests {
    static let gesture = ReprogrammableControl(
        control: 0x00C3,
        task: 0xA9,
        flags: [.divertable, .rawXY],
        reporting: nil
    )
    static let modeShift = ReprogrammableControl(control: 0x00C4, task: 0x9D, flags: [.divertable], reporting: nil)
    static let left = ReprogrammableControl(control: 0x0050, task: 0x38, flags: [.mouseButton], reporting: nil)
    static let gestureSetting = RestorableSetting.controlReporting(DeviceControlID(rawValue: 0x00C3))
    static let modeShiftSetting = RestorableSetting.controlReporting(DeviceControlID(rawValue: 0x00C4))

    struct Rig {
        let device: FakeReprogDevice
        let store: InMemoryJournalStore
        let ledger: RestorationLedger
        let transaction: ControlDivertTransaction<HIDPPChannel<ManualClock>>
        let clock: ManualClock
    }

    static func target(
        identity: DeviceID = .fixture(1),
        physical: PhysicalDeviceID = FakeReprogDevice.defaultPhysicalID
    ) -> ConfigurableDevice {
        ConfigurableDevice(
            identity: identity,
            physical: physical,
            deviceIndex: .direct,
            reprogIndex: FeatureIndex(rawValue: 1),
            informationIndex: FeatureIndex(rawValue: 2)
        )
    }

    static func rig(
        device: FakeReprogDevice = FakeReprogDevice(),
        store: InMemoryJournalStore = InMemoryJournalStore(),
        target: ConfigurableDevice = target(),
        authorization: DeviceWriteAuthorization = .enabled
    ) async -> Rig {
        let clock = ManualClock()
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: device.responder), clock: clock)
        await channel.start()
        let ledger = RestorationLedger(store: store)
        _ = await ledger.load()
        let transaction = ControlDivertTransaction(
            connection: channel,
            target: target,
            ledger: ledger,
            authorization: authorization,
            timeout: .seconds(1)
        )
        return Rig(device: device, store: store, ledger: ledger, transaction: transaction, clock: clock)
    }

    @Test("diverting records the original durably first, writes 0x33 once, and verifies by reading back")
    func divert() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)

        #expect(rig.device.reportingFlags(of: 0x00C3) == 0x11)
        #expect(rig.device.writeLog.map(\.1) == [0x33])
        #expect(
            rig.store.persisted.pending(for: rig.store.key(for: .fixture(1))).map(\.original)
                == [.controlReporting(diverted: false, rawXYDiverted: false)]
        )
    }

    @Test("writes are refused before anything is sent when not authorized")
    func unauthorized() async throws {
        let rig = await Self.rig(authorization: .disabled)
        await #expect(throws: DeviceConfigurationError.writesNotAuthorized) {
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.store.saves == 0)
    }

    @Test("an undivert command cannot be used to divert")
    func undivertIsNotADivert() async {
        let rig = await Self.rig()
        await #expect(throws: DeviceConfigurationError.unsupportedCombination(0x00C3)) {
            try await rig.transaction.divert(Self.gesture, with: .undivertWithRawXY)
        }
        #expect(rig.device.writeLog.isEmpty)
    }

    @Test("raw XY is refused on a control that does not support it")
    func rawXYUnsupported() async {
        let rig = await Self.rig()
        await #expect(throws: DeviceConfigurationError.unsupportedCombination(0x00C4)) {
            try await rig.transaction.divert(Self.modeShift, with: .divertWithRawXY)
        }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a control the firmware does not allow to divert is never written")
    func notDivertable() async {
        let rig = await Self.rig()
        await #expect(throws: DeviceConfigurationError.notDivertable(0x0050)) {
            try await rig.transaction.divert(Self.left, with: .divertButtonOnly)
        }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.store.persisted.isClean)
    }

    @Test(
        "a control diverted, persistently diverted or remapped by something else is not taken over",
        arguments: [(UInt8(0x01), UInt16(0)), (0x04, 0), (0x10, 0), (0x00, 0x0052)]
    )
    func foreignState(flags: UInt8, remap: UInt16) async {
        let device = FakeReprogDevice()
        device.setReportingFlags(flags, of: 0x00C3)
        if remap != 0 { device.setRemap(remap, of: 0x00C3) }
        let rig = await Self.rig(device: device)
        await #expect(throws: DeviceConfigurationError.foreignState(0x00C3)) {
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.store.persisted.isClean)
    }

    @Test("if the recovery record cannot be stored, the device is not changed")
    func journalUnavailable() async {
        let rig = await Self.rig()
        rig.store.failNextSaves(1)
        await #expect(throws: DeviceConfigurationError.journalUnavailable(.fileSystem("injected"))) {
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0)
    }

    @Test("regression: a different physical unit behind the same identity is never written")
    func staleIdentity() async {
        let device = FakeReprogDevice()
        device.setIdentity(unit: 0x0BAD_0BAD, model: FakeReprogDevice.defaultModel)
        let rig = await Self.rig(device: device)
        await #expect(throws: DeviceConfigurationError.identityMismatch) {
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        #expect(device.writeLog.isEmpty)
        #expect(rig.store.persisted.isClean)
    }

    @Test("regression: an unreadable identity blocks diverting and restoring and keeps the record")
    func unknownIdentity() async throws {
        let device = FakeReprogDevice()
        let rig = await Self.rig(device: device)
        try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        device.hideIdentity()

        let report = await rig.transaction.restoreAll()

        #expect(report.failed == [Self.gestureSetting: .identityMismatch])
        #expect(device.writeLog.count == 1)
        #expect(rig.store.persisted.entries.count == 1)
    }

    @Test("regression: a device that ignores the write is rolled back for that control only")
    func scopedRollback() async throws {
        let device = FakeReprogDevice()
        let rig = await Self.rig(device: device)
        try await rig.transaction.divert(Self.modeShift, with: .divertButtonOnly)
        // The gesture's raw XY bit does not take: the device lands on button-only divert.
        device.onWrite { control in
            if control == 0x00C3, device.reportingFlags(of: 0x00C3) == 0x11 {
                device.setReportingFlags(0x01, of: 0x00C3)
            }
        }

        await #expect(throws: DeviceConfigurationError.verificationFailed(0x00C3)) {
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(device.reportingFlags(of: 0x00C4) == 0x01)
        #expect(rig.store.persisted.entries.map(\.setting) == [Self.modeShiftSetting])
    }

    @Test("a device that acknowledges but ignores the write fails verification; the record is kept")
    func verificationFailure() async {
        let device = FakeReprogDevice()
        device.setFault(.ignoresWrites)
        let rig = await Self.rig(device: device)
        await #expect(throws: DeviceConfigurationError.verificationFailed(0x00C3)) {
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        // Still native, so the rollback needs no write and confirms the entry.
        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a failed divert write keeps the record (the state is unknown until read again)")
    func failedDivertWrite() async throws {
        let device = FakeReprogDevice()
        device.failWrites(to: [0x00C3])
        let rig = await Self.rig(device: device)
        await #expect(throws: DeviceConfigurationError.self) {
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        #expect(rig.store.persisted.entries.count == 1)
        device.failWrites(to: [])
        #expect(await rig.transaction.restoreAll().isComplete)
        #expect(rig.store.persisted.isClean)
    }

    @Test("cancellation before the write leaves the device unchanged and the record in place")
    func cancelledBeforeWrite() async throws {
        let rig = await Self.rig()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        }
        await #expect(throws: DeviceConfigurationError.self) { try await task.value }
        #expect(rig.device.writeLog.isEmpty)
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0)
    }

    @Test("regression: a restore and a divert of one device never interleave")
    func serialized() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.modeShift, with: .divertButtonOnly)
        async let restoring = rig.transaction.restoreAll()
        async let diverting: Void = rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        _ = await restoring
        try await diverting

        // Either order leaves a consistent device/journal pair: every diverted control has an entry.
        let pending = Set(rig.store.persisted.entries.map(\.setting))
        for control in [UInt16(0x00C3), 0x00C4] where rig.device.reportingFlags(of: control) != 0 {
            #expect(pending.contains(.controlReporting(DeviceControlID(rawValue: control))))
        }
        let writes = rig.device.writeLog.map(\.1)
        #expect(writes == [0x03, 0x02, 0x33] || writes == [0x03, 0x33, 0x22, 0x02])
    }

    @Test("persistent divert bits are never written by any path")
    func neverPersistent() async throws {
        let rig = await Self.rig()
        try await rig.transaction.divert(Self.gesture, with: .divertWithRawXY)
        try await rig.transaction.divert(Self.modeShift, with: .divertButtonOnly)
        _ = await rig.transaction.restoreAll()

        #expect(rig.device.writeLog.allSatisfy { $0.1 & 0xCC == 0 })
    }
}
