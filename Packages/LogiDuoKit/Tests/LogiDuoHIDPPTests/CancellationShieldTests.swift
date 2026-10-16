import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

/// Makes a device answer asynchronously, the way real hardware does, so a
/// cancelled caller's requests really are cancelled before the reply arrives.
func slowResponses(
    _ transport: FakeHIDPPTransport,
    device: FakeReprogDevice,
    latency: some Clock<Duration> = ContinuousClock()
) {
    transport.setResponder { sent in
        let replies = device.responder(sent)
        Task {
            try? await latency.sleep(for: .milliseconds(5))
            for reply in replies { transport.deliver(reply) }
        }
        return []
    }
}

@Suite("Restoration under cancellation (fake device only)", .timeLimit(.minutes(1)))
struct CancellationShieldTests {
    private typealias Rigs = ControlDivertTransactionTests

    private struct Diverted {
        let device: FakeReprogDevice
        let channel: HIDPPChannel<ContinuousClock>
        let ledger: RestorationLedger
        let store: InMemoryJournalStore
    }

    private static func diverted() async throws -> Diverted {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let transport = FakeHIDPPTransport(responder: device.responder)
        let channel = HIDPPChannel(transport: transport, clock: ContinuousClock())
        await channel.start()
        let ledger = RestorationLedger(store: store)
        _ = await ledger.load()
        let transaction = ControlDivertTransaction(
            connection: channel,
            target: Rigs.target(),
            ledger: ledger,
            authorization: .enabled,
            timeout: .seconds(1)
        )
        try await transaction.divert(Rigs.gesture, with: .divertWithRawXY)
        slowResponses(transport, device: device)
        return Diverted(device: device, channel: channel, ledger: ledger, store: store)
    }

    @Test("regression: restoreAll from a cancelled task still restores and clears the record")
    func restoreAllShielded() async throws {
        let diverted = try await Self.diverted()
        let (device, channel, ledger, store) = (diverted.device, diverted.channel, diverted.ledger, diverted.store)
        let transaction = ControlDivertTransaction(
            connection: channel,
            target: Rigs.target(),
            ledger: ledger,
            authorization: .enabled,
            timeout: .seconds(1)
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await transaction.restoreAll()
        }

        #expect(await task.value.isComplete)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(store.persisted.isClean)
    }

    @Test("regression: a confirmed emergency reset completes even if the caller is cancelled")
    func resetShielded() async throws {
        let diverted = try await Self.diverted()
        let (device, channel, ledger) = (diverted.device, diverted.channel, diverted.ledger)
        let recovery = DeviceRecovery(
            connection: channel,
            target: Rigs.target(),
            ledger: ledger,
            authorization: .enabled,
            timeout: .seconds(1)
        )
        let plan = try await recovery.planEmergencyReset()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await recovery.performEmergencyReset(
                plan,
                confirmation: EmergencyResetConfirmation(userConfirmed: plan)
            )
        }

        #expect(await task.value.outcomes[0x00C3] == .reset)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
    }
}
