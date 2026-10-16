import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

/// Simulated LogiDuo runs over one persistent fake device and journal store.
enum RecoveryRigs {
    typealias Rigs = ControlDivertTransactionTests

    struct Rig {
        let device: FakeReprogDevice
        let store: InMemoryJournalStore
        let ledger: RestorationLedger
        let transaction: ControlDivertTransaction<HIDPPChannel<ManualClock>>
        let recovery: DeviceRecovery<HIDPPChannel<ManualClock>>
        let loaded: RestorationLedger.LoadOutcome

        /// Where the in-memory store reports quarantined journals.
        var quarantine: URL { URL(fileURLWithPath: "/dev/null") }
    }

    /// One "run" of LogiDuo: a fresh channel and ledger over the persistent store and device.
    static func launch(
        device: FakeReprogDevice,
        store: InMemoryJournalStore,
        target: ConfigurableDevice = Rigs.target(),
        authorization: DeviceWriteAuthorization = .enabled
    ) async -> Rig {
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: device.responder), clock: ManualClock())
        await channel.start()
        let ledger = RestorationLedger(store: store)
        let loaded = await ledger.load()
        return Rig(
            device: device,
            store: store,
            ledger: ledger,
            transaction: ControlDivertTransaction(
                connection: channel,
                target: target,
                ledger: ledger,
                authorization: authorization,
                timeout: .seconds(1)
            ),
            recovery: DeviceRecovery(
                connection: channel,
                target: target,
                ledger: ledger,
                authorization: authorization,
                timeout: .seconds(1)
            ),
            loaded: loaded
        )
    }

    static func diverted() async throws -> (FakeReprogDevice, InMemoryJournalStore) {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let first = await Self.launch(device: device, store: store)
        try await first.transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        try await first.transaction.divert(Rigs.modeShift, with: .divertButtonOnly)
        return (device, store)
    }
}
