import Foundation
import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoTestSupport
import Testing

actor FakeRecoveryService: DeviceRecoveryServicing {
    var status = RecoveryJournalStatus.pending(entries: 2)
    var listed: [RecoveryDevice]
    var proposal: Result<EmergencyResetProposal, RecoveryBlock>
    var performed: [EmergencyResetProposal] = []
    var restored: [DeviceID] = []
    var acknowledged = 0
    var listings = 0

    static let device: RecoveryDevice = {
        guard let model = ModelID(rawValue: 0xB034_0000_0000) else { preconditionFailure("valid") }
        return RecoveryDevice(id: .fixture(1), name: "MX Master 3S", model: model, pendingRecords: 2)
    }()

    static let plan = EmergencyResetProposal(
        id: UUID(),
        device: device,
        controls: [
            RecoveryControl(control: DeviceControlID(rawValue: 0x00C3), plan: .willReset),
            RecoveryControl(control: DeviceControlID(rawValue: 0x00C4), plan: .skippedPersistent),
        ],
        journalCorrupted: false
    )

    init(proposal: Result<EmergencyResetProposal, RecoveryBlock> = .success(plan)) {
        listed = [Self.device]
        self.proposal = proposal
    }

    func journalStatus() -> RecoveryJournalStatus { status }
    func devices() -> [RecoveryDevice] {
        listings += 1
        return listed
    }
    func exactRestore(_ device: DeviceID) -> RecoveryResult {
        restored.append(device)
        status = .clean
        return RecoveryResult(outcomes: [DeviceControlID(rawValue: 0x00C3): .restored])
    }
    func proposeEmergencyReset(_ device: DeviceID) -> Result<EmergencyResetProposal, RecoveryBlock> { proposal }
    func performEmergencyReset(userConfirmed proposal: EmergencyResetProposal) -> RecoveryResult {
        performed.append(proposal)
        return RecoveryResult(outcomes: [DeviceControlID(rawValue: 0x00C3): .restored])
    }
    func acknowledgeCorruption() {
        acknowledged += 1
        status = .clean
    }
    func setStatus(_ status: RecoveryJournalStatus) { self.status = status }
}

@MainActor
@Suite("RecoveryViewModel")
struct RecoveryViewModelTests {
    @Test("refresh shows the journal status and verified devices")
    func refresh() async {
        let model = RecoveryViewModel(service: FakeRecoveryService(), writesEnabled: false)
        await model.refresh()
        #expect(model.journal == .pending(entries: 2))
        #expect(model.devices.map(\.name) == ["MX Master 3S"])
        #expect(!model.writesEnabled)
    }

    @Test("the launch check reads only the journal and opens no device")
    func launchCheck() async {
        let service = FakeRecoveryService()
        let model = RecoveryViewModel(service: service, writesEnabled: false)
        await model.refreshJournal()
        #expect(model.journal == .pending(entries: 2))
        #expect(await service.listings == 0)
    }

    @Test("exact restore runs directly and refreshes")
    func exactRestore() async {
        let service = FakeRecoveryService()
        let model = RecoveryViewModel(service: service, writesEnabled: true)
        await model.restore(.fixture(1))
        #expect(await service.restored == [.fixture(1)])
        #expect(model.journal == .clean)
        guard case .finished(let result) = model.phase else {
            Issue.record("expected a result")
            return
        }
        #expect(result.isComplete)
    }

    @Test("reviewing shows the plan and performs nothing")
    func reviewOnly() async {
        let service = FakeRecoveryService()
        let model = RecoveryViewModel(service: service, writesEnabled: true)
        await model.reviewEmergencyReset(.fixture(1))
        #expect(model.proposal == FakeRecoveryService.plan)
        #expect(model.proposal?.changes.count == 1)
        #expect(!model.isConfirmingReset)
        #expect(await service.performed.isEmpty)
    }

    @Test("declining the emergency reset discards the plan and performs nothing")
    func decline() async {
        let service = FakeRecoveryService()
        let model = RecoveryViewModel(service: service, writesEnabled: true)
        await model.reviewEmergencyReset(.fixture(1))
        model.requestConfirmation()
        #expect(model.isConfirmingReset)

        model.declineEmergencyReset()

        #expect(model.phase == .idle)
        #expect(!model.isConfirmingReset)
        await model.confirmEmergencyReset()
        #expect(await service.performed.isEmpty)
    }

    @Test("confirming performs exactly the reviewed plan, once")
    func confirm() async {
        let service = FakeRecoveryService()
        let model = RecoveryViewModel(service: service, writesEnabled: true)
        await model.reviewEmergencyReset(.fixture(1))
        model.requestConfirmation()

        await model.confirmEmergencyReset()
        await model.confirmEmergencyReset()

        #expect(await service.performed == [FakeRecoveryService.plan])
        #expect(model.proposal == nil)
    }

    @Test("confirming without a reviewed plan does nothing")
    func confirmWithoutPlan() async {
        let service = FakeRecoveryService()
        let model = RecoveryViewModel(service: service, writesEnabled: true)
        model.requestConfirmation()
        #expect(!model.isConfirmingReset)
        await model.confirmEmergencyReset()
        #expect(await service.performed.isEmpty)
    }

    @Test("a plan without changes cannot be confirmed")
    func nothingToReset() async {
        let unchanged = EmergencyResetProposal(
            id: UUID(),
            device: FakeRecoveryService.device,
            controls: [RecoveryControl(control: DeviceControlID(rawValue: 0x00C3), plan: .alreadyNative)],
            journalCorrupted: false
        )
        let model = RecoveryViewModel(service: FakeRecoveryService(proposal: .success(unchanged)), writesEnabled: true)
        await model.reviewEmergencyReset(.fixture(1))
        model.requestConfirmation()
        #expect(!model.isConfirmingReset)
    }

    @Test("an unverified identity is shown as blocked")
    func blocked() async {
        let model = RecoveryViewModel(
            service: FakeRecoveryService(proposal: .failure(.identityUnverified)),
            writesEnabled: true
        )
        await model.reviewEmergencyReset(.fixture(1))
        #expect(model.phase == .blocked(.identityUnverified))
    }

    @Test("a corrupted journal is shown until the person acknowledges it, and nothing runs on its own")
    func corrupted() async {
        let service = FakeRecoveryService()
        await service.setStatus(.corrupted)
        let model = RecoveryViewModel(service: service, writesEnabled: true)
        await model.refresh()
        #expect(model.journal == .corrupted)
        #expect(await service.performed.isEmpty)
        #expect(await service.restored.isEmpty)

        await model.acknowledgeCorruption()
        #expect(await service.acknowledged == 1)
        #expect(model.journal == .clean)
    }
}
