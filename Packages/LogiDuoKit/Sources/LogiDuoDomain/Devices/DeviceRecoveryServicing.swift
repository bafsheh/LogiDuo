public import Foundation

/// What the restoration journal says about earlier runs.
public enum RecoveryJournalStatus: Hashable, Sendable {
    /// Nothing to restore.
    case clean
    /// Changes from an earlier run are still recorded and waiting to be undone.
    case pending(entries: Int)
    /// The journal was unreadable. It was kept aside; device state is unknown.
    case corrupted
}

/// A connected device recovery can work on; its physical identity was verified.
public struct RecoveryDevice: Hashable, Sendable, Identifiable {
    /// The stable identifier (derived from the physical identity).
    public let id: DeviceID
    /// The name the device reports.
    public let name: String
    /// The device model.
    public let model: ModelID
    /// How many recovery records exist for it.
    public let pendingRecords: Int

    /// Creates a description.
    public init(id: DeviceID, name: String, model: ModelID, pendingRecords: Int) {
        self.id = id
        self.name = name
        self.model = model
        self.pendingRecords = pendingRecords
    }
}

/// Why a recovery step did not run.
public enum RecoveryBlock: Error, Hashable, Sendable {
    /// Device configuration writes are disabled in this build or session.
    case writesDisabled
    /// The device's physical identity is unknown or different from the expected one.
    case identityUnverified
    /// The person did not confirm this exact plan (or it is out of date).
    case notConfirmed
    /// The device is not connected or does not answer.
    case deviceUnavailable
    /// Exact restore needs a readable journal.
    case journalCorrupted
    /// The device has no reprogrammable controls.
    case unsupportedDevice
}

/// What an emergency reset will do to one managed control.
public enum RecoveryControlPlan: Hashable, Sendable {
    /// Temporarily diverted: it will be returned to normal.
    case willReset
    /// Already normal: nothing will be written.
    case alreadyNative
    /// Stored (persistent) divert, not LogiDuo's: left alone.
    case skippedPersistent
    /// Remapped to another control, not LogiDuo's: left alone.
    case skippedRemapped
    /// Not divertable: left alone.
    case skippedNotDivertable
    /// Unexpected state: left alone.
    case skippedUnexpected
}

/// One managed control in a proposal.
public struct RecoveryControl: Hashable, Sendable {
    /// The control.
    public let control: DeviceControlID
    /// What will happen to it.
    public let plan: RecoveryControlPlan

    /// Creates a description.
    public init(control: DeviceControlID, plan: RecoveryControlPlan) {
        self.control = control
        self.plan = plan
    }
}

/// A read-only emergency-reset plan, shown to the person before anything changes.
public struct EmergencyResetProposal: Hashable, Sendable, Identifiable {
    /// Identifies the plan; a confirmation applies to this plan only.
    public let id: UUID
    /// The verified device.
    public let device: RecoveryDevice
    /// Every managed control and what will happen to it.
    public let controls: [RecoveryControl]
    /// Whether the journal was unreadable.
    public let journalCorrupted: Bool

    /// The controls that will be written.
    public var changes: [RecoveryControl] { controls.filter { $0.plan == .willReset } }

    /// Creates a proposal.
    public init(id: UUID, device: RecoveryDevice, controls: [RecoveryControl], journalCorrupted: Bool) {
        self.id = id
        self.device = device
        self.controls = controls
        self.journalCorrupted = journalCorrupted
    }
}

/// What happened to one control.
public enum RecoveryControlOutcome: Hashable, Sendable {
    /// Returned to normal and verified by reading it back.
    case restored
    /// Was already normal.
    case alreadyNative
    /// Left alone, as planned.
    case skipped
    /// Changed after the plan was made, so it was not written.
    case changedSincePlanning
    /// The write or the verification failed; its record (if any) is kept.
    case failed
}

/// The result of a recovery step.
public struct RecoveryResult: Hashable, Sendable {
    /// Why nothing ran, if so.
    public var blocked: RecoveryBlock?
    /// Each control's outcome.
    public var outcomes: [DeviceControlID: RecoveryControlOutcome]
    /// Recorded settings other than controls that could not be restored.
    public var otherFailures: Int
    /// Whether the outcome could not be saved to the journal (records kept for a retry).
    public var journalSaveFailed: Bool

    /// Creates a result.
    public init(
        blocked: RecoveryBlock? = nil,
        outcomes: [DeviceControlID: RecoveryControlOutcome] = [:],
        otherFailures: Int = 0,
        journalSaveFailed: Bool = false
    ) {
        self.blocked = blocked
        self.outcomes = outcomes
        self.otherFailures = otherFailures
        self.journalSaveFailed = journalSaveFailed
    }

    /// Whether everything ran and was verified.
    public var isComplete: Bool {
        blocked == nil && otherFailures == 0 && !journalSaveFailed
            && outcomes.values.allSatisfy { $0 != .failed && $0 != .changedSincePlanning }
    }
}

/// Manual device recovery, independent of remapping, the event tap and gestures.
public protocol DeviceRecoveryServicing: Sendable {
    /// The journal's status.
    func journalStatus() async -> RecoveryJournalStatus
    /// Connected devices with a verified physical identity.
    func devices() async -> [RecoveryDevice]
    /// Undoes exactly what valid records describe for `device`, verifying each control.
    func exactRestore(_ device: DeviceID) async -> RecoveryResult
    /// Plans an emergency reset of `device` without changing anything.
    func proposeEmergencyReset(_ device: DeviceID) async -> Result<EmergencyResetProposal, RecoveryBlock>
    /// Performs `proposal`. Call only after the person explicitly confirmed it.
    func performEmergencyReset(userConfirmed proposal: EmergencyResetProposal) async -> RecoveryResult
    /// Records that the person has seen the corrupted-journal notice. The kept file is not deleted.
    func acknowledgeCorruption() async
}
