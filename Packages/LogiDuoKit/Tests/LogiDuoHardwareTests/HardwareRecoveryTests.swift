import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

/// A journal that lives only in memory, so the hardware run never touches the real file.
private final class EphemeralJournalStore: RestorationJournalStoring, @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private var journal = RestorationJournal()

    func load() -> RestorationJournal { lock.withLock { journal } }
    func save(_ updated: RestorationJournal) { lock.withLock { journal = updated } }
    func key(for device: DeviceID) -> RestorationDeviceKey {
        RestorationDeviceKey(rawValue: "ephemeral:" + device.rawValue)
    }
}

@Suite(
    "Hardware: recovery inspection (read-only, writes disabled)",
    .enabled(if: logitechEndpointPresent),
    .serialized,
    .timeLimit(.minutes(2))
)
struct HardwareRecoveryTests {
    @Test("locates, verifies the unit and plans an emergency reset without writing")
    func planReadOnly() async throws {
        let ledger = RestorationLedger(store: EphemeralJournalStore())
        _ = await ledger.load()
        let endpoints = await LiveRecoveryConnector.endpoints(ledger: ledger, authorization: .disabled)
        print("[recovery] \(endpoints.count) verified endpoint(s)")
        for endpoint in endpoints {
            let plan = try await endpoint.session.planEmergencyReset()
            print("[recovery] \(endpoint.name) model=\(plan.device.physical.model) managed=\(plan.items.count)")
            if ProcessInfo.processInfo.environment["LOGIDUO_SHOW_UNIT"] == "1" {
                // Printed only on request: the unit identifier arms the first-write experiment.
                print("[recovery] \(endpoint.name) unit=\(String(plan.device.physical.unit.rawValue, radix: 16))")
            }
            for item in plan.items {
                let flags = String(item.observed.flags, radix: 16)
                print(
                    "[recovery]   cid=0x\(String(item.control, radix: 16)) reporting=0x\(flags) -> \(item.disposition)"
                )
            }
            let report = await endpoint.session.performEmergencyReset(
                plan,
                confirmation: EmergencyResetConfirmation(userConfirmed: plan)
            )
            #expect(report.blocked == .writesNotAuthorized)
            await endpoint.close()
        }
    }
}
