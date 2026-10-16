import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("HIDPPRecoveryService and RecoveryDeviceLocator (fake device only)", .timeLimit(.minutes(1)))
struct HIDPPRecoveryServiceTests {
    private typealias Rigs = ControlDivertTransactionTests

    private static func service(
        _ rig: RecoveryRigs.Rig,
        name: String = "MX Master 3S"
    ) -> HIDPPRecoveryService {
        let endpoint = RecoveryEndpoint(name: name, session: rig.recovery)
        return HIDPPRecoveryService(ledger: rig.ledger) { [endpoint] }
    }

    private static var deviceID: DeviceID { Rigs.target().identity }

    @Test("journal status distinguishes clean, pending and corrupted")
    func journalStatus() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        #expect(
            await Self.service(await RecoveryRigs.launch(device: device, store: store)).journalStatus()
                == .pending(entries: 2)
        )
        store.corrupt()
        #expect(
            await Self.service(await RecoveryRigs.launch(device: device, store: store)).journalStatus() == .corrupted
        )
        let clean = await RecoveryRigs.launch(device: FakeReprogDevice(), store: InMemoryJournalStore())
        #expect(await Self.service(clean).journalStatus() == .clean)
    }

    @Test("devices are listed with their pending records; exact restore maps per control")
    func listAndRestore() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let service = Self.service(await RecoveryRigs.launch(device: device, store: store))

        let devices = await service.devices()
        #expect(devices.map(\.pendingRecords) == [2])
        let result = await service.exactRestore(Self.deviceID)

        #expect(result.isComplete)
        #expect(
            result.outcomes == [
                DeviceControlID(rawValue: 0x00C3): .restored, DeviceControlID(rawValue: 0x00C4): .restored,
            ]
        )
        #expect(await service.journalStatus() == .clean)
    }

    @Test("a proposal is shown before anything is written, and can be performed once")
    func proposeThenPerformOnce() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let service = Self.service(await RecoveryRigs.launch(device: device, store: store))
        _ = await service.devices()
        let before = device.writeLog.count

        let proposal = try await service.proposeEmergencyReset(Self.deviceID).get()
        #expect(device.writeLog.count == before)
        #expect(proposal.changes.map(\.control.rawValue) == [0x00C3, 0x00C4])
        #expect(proposal.device.name == "MX Master 3S")

        #expect(await service.performEmergencyReset(userConfirmed: proposal).isComplete)
        #expect(await service.performEmergencyReset(userConfirmed: proposal).blocked == .notConfirmed)
        #expect(device.writeLog.count == before + 2)
    }

    @Test("an older proposal is superseded and refused")
    func supersededProposal() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let service = Self.service(await RecoveryRigs.launch(device: device, store: store))
        _ = await service.devices()
        let older = try await service.proposeEmergencyReset(Self.deviceID).get()
        _ = try await service.proposeEmergencyReset(Self.deviceID).get()
        let before = device.writeLog.count

        #expect(await service.performEmergencyReset(userConfirmed: older).blocked == .notConfirmed)
        #expect(device.writeLog.count == before)
    }

    @Test("a fabricated proposal is refused")
    func fabricatedProposal() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let service = Self.service(await RecoveryRigs.launch(device: device, store: store))
        let devices = await service.devices()
        let fabricated = EmergencyResetProposal(
            id: UUID(),
            device: try #require(devices.first),
            controls: [RecoveryControl(control: DeviceControlID(rawValue: 0x00C3), plan: .willReset)],
            journalCorrupted: false
        )
        #expect(await service.performEmergencyReset(userConfirmed: fabricated).blocked == .notConfirmed)
    }

    @Test("with writes disabled everything is inspectable and nothing is written")
    func writesDisabled() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let service = Self.service(await RecoveryRigs.launch(device: device, store: store, authorization: .disabled))
        _ = await service.devices()
        let before = device.writeLog.count

        #expect(await service.exactRestore(Self.deviceID).blocked == .writesDisabled)
        let proposal = try await service.proposeEmergencyReset(Self.deviceID).get()
        #expect(await service.performEmergencyReset(userConfirmed: proposal).blocked == .writesDisabled)
        #expect(device.writeLog.count == before)
        #expect(store.persisted.entries.count == 2)
    }

    @Test("an unknown identity is reported as unverified, never reset")
    func identityUnverified() async throws {
        let (device, store) = try await RecoveryRigs.diverted()
        let service = Self.service(await RecoveryRigs.launch(device: device, store: store))
        _ = await service.devices()
        device.hideIdentity()

        #expect(await service.exactRestore(Self.deviceID).blocked == .identityUnverified)
        #expect(await service.proposeEmergencyReset(Self.deviceID) == .failure(.identityUnverified))
    }

    @Test("a device that is not connected is unavailable")
    func unavailable() async {
        let service = HIDPPRecoveryService(ledger: RestorationLedger(store: InMemoryJournalStore())) { [] }
        #expect(await service.devices().isEmpty)
        #expect(await service.exactRestore(Self.deviceID).blocked == .deviceUnavailable)
        #expect(await service.proposeEmergencyReset(Self.deviceID) == .failure(.deviceUnavailable))
    }

    @Test("acknowledging corruption unblocks new records but keeps the status visible until then")
    func acknowledge() async {
        let store = InMemoryJournalStore()
        store.corrupt()
        let rig = await RecoveryRigs.launch(device: FakeReprogDevice(), store: store)
        let service = Self.service(rig)
        #expect(await service.journalStatus() == .corrupted)
        await service.acknowledgeCorruption()
        #expect(await service.journalStatus() == .clean)
    }

    @Test("the locator derives the identity from the firmware and refuses devices without one")
    func locator() async {
        let device = FakeReprogDevice()
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: device.responder), clock: ManualClock())
        await channel.start()

        let located = await RecoveryDeviceLocator.locate(via: channel, deviceIndex: .direct, timeout: nil)
        #expect(
            (try? located.get())?.target
                == Rigs.target(identity: DeviceID(physical: FakeReprogDevice.defaultPhysicalID))
        )
        #expect((try? located.get())?.name == "Logitech device")

        device.hideIdentity()
        let hidden = await RecoveryDeviceLocator.locate(via: channel, deviceIndex: .direct, timeout: nil)
        #expect(hidden.map(\.target) == .failure(.identityUnverified))
    }

    @Test("the physical device identifier matches the identity registry's")
    func physicalIdentifier() {
        var registry = DeviceIdentityRegistry()
        let observation = IdentityFixtures.observation(
            IdentityFixtures.bluetooth(),
            physical: FakeReprogDevice.defaultPhysicalID
        )
        #expect(registry.reconcile(observation).identity.id == DeviceID(physical: FakeReprogDevice.defaultPhysicalID))
    }
}
