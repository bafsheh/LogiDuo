public import LogiDuoDomain
public import Observation

/// Presentation state and intents for the device recovery screen.
///
/// Works without remapping, the event tap or gestures. An emergency reset is a
/// two-step flow: ``reviewEmergencyReset(_:)`` shows a read-only plan, and only
/// ``confirmEmergencyReset()`` — bound to the confirmation dialog's destructive
/// button — performs it. Declining discards the plan.
@MainActor
@Observable
public final class RecoveryViewModel {
    /// What the screen is doing.
    public enum Phase: Hashable, Sendable {
        /// Nothing in progress.
        case idle
        /// A request is running.
        case working
        /// A plan is shown and awaits the person's decision.
        case reviewing(EmergencyResetProposal)
        /// The last step's result.
        case finished(RecoveryResult)
        /// The last step could not run.
        case blocked(RecoveryBlock)
    }

    /// The journal's status.
    public private(set) var journal: RecoveryJournalStatus = .clean
    /// Connected devices with a verified identity.
    public private(set) var devices: [RecoveryDevice] = []
    /// The current phase.
    public private(set) var phase: Phase = .idle
    /// Whether the confirmation dialog is shown.
    public var isConfirmingReset = false
    /// Whether this build may change devices; when not, recovery only inspects.
    public let writesEnabled: Bool

    private let service: any DeviceRecoveryServicing

    /// Creates a view model.
    public init(service: any DeviceRecoveryServicing, writesEnabled: Bool) {
        self.service = service
        self.writesEnabled = writesEnabled
    }

    /// The plan under review, if any.
    public var proposal: EmergencyResetProposal? {
        if case .reviewing(let proposal) = phase { return proposal }
        return nil
    }

    /// Reloads the journal status and the device list (opens the connected devices read-only).
    public func refresh() async {
        await refreshJournal()
        devices = await service.devices()
    }

    /// Reloads only the journal status; no device is opened.
    public func refreshJournal() async {
        journal = await service.journalStatus()
    }

    /// Undoes exactly what the records describe for `device`.
    public func restore(_ device: DeviceID) async {
        phase = .working
        finish(await service.exactRestore(device))
        await refresh()
    }

    /// Shows what an emergency reset of `device` would change, without changing anything.
    public func reviewEmergencyReset(_ device: DeviceID) async {
        phase = .working
        switch await service.proposeEmergencyReset(device) {
        case .success(let proposal): phase = .reviewing(proposal)
        case .failure(let block): phase = .blocked(block)
        }
    }

    /// Opens the confirmation dialog for the plan under review.
    public func requestConfirmation() {
        guard proposal?.changes.isEmpty == false else { return }
        isConfirmingReset = true
    }

    /// Performs the plan under review. Call only from the dialog's confirm action.
    public func confirmEmergencyReset() async {
        isConfirmingReset = false
        guard let proposal else { return }
        phase = .working
        finish(await service.performEmergencyReset(userConfirmed: proposal))
        await refresh()
    }

    /// Discards the plan under review; nothing is changed.
    public func declineEmergencyReset() {
        isConfirmingReset = false
        if proposal != nil { phase = .idle }
    }

    /// Records that the person has read the corrupted-journal notice.
    public func acknowledgeCorruption() async {
        await service.acknowledgeCorruption()
        await refresh()
    }

    private func finish(_ result: RecoveryResult) {
        phase = result.blocked.map(Phase.blocked) ?? .finished(result)
    }
}
