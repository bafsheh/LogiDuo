public import LogiDuoDomain

/// The only operations the experiment harness can perform. There is no way to pass
/// a control identifier, a device identifier or raw bytes.
public enum ExperimentOperation: Hashable, Sendable, CaseIterable {
    /// MX Master 3S over Bluetooth: one temporary button-only divert of the gesture
    /// button (`0x00C3`, command `0x03`), then exact restoration (`0x02`).
    case mxMaster3SGestureDivertOnce

    /// The control the operation touches.
    var control: UInt16 { 0x00C3 }

    /// The single divert the operation sends.
    var command: ReportingCommand { .divertButtonOnly }

    /// Whether `model` is the device family the operation is approved for.
    func approves(_ model: ModelID) -> Bool {
        // The MX Master 3S reports its Bluetooth product 0xB034 in the first model slot.
        model.rawValue >> 32 == 0xB034
    }
}

/// A single-use permission for one operation on one physical unit within one session.
///
/// Created only by ``ExperimentSession/authorize(_:expectedUnit:)``; redeemed at most
/// once, and only by the session that issued it.
public struct ExperimentAuthorization: Hashable, Sendable {
    let session: UInt64
    let nonce: UInt64
    /// The operation it permits.
    public let operation: ExperimentOperation
    /// The unit it is bound to.
    public let expectedUnit: UnitID
}

/// Issues and redeems ``ExperimentAuthorization`` tokens.
///
/// A session is created for one supervised run; its tokens are useless in any other
/// session, and each token works once.
public actor ExperimentSession {
    private let id = UInt64.random(in: .min ... .max)
    private var outstanding: Set<UInt64> = []

    /// Creates a session.
    public init() {}

    /// Issues a token. Call only after the person explicitly approved this exact run.
    public func authorize(_ operation: ExperimentOperation, expectedUnit: UnitID) -> ExperimentAuthorization {
        let nonce = UInt64.random(in: .min ... .max)
        outstanding.insert(nonce)
        return ExperimentAuthorization(session: id, nonce: nonce, operation: operation, expectedUnit: expectedUnit)
    }

    /// Consumes `token`; `false` if it is foreign, unknown or already used.
    func redeem(_ token: ExperimentAuthorization) -> Bool {
        guard token.session == id else { return false }
        return outstanding.remove(token.nonce) != nil
    }
}

/// Why the experiment stopped before or during the change.
public enum ExperimentAbort: Error, Hashable, Sendable {
    /// The token is foreign, unknown or already used.
    case notAuthorized
    /// The device is not connected over Bluetooth.
    case notBluetooth
    /// The device is not the approved model or not the expected unit, or its identity is unreadable.
    case identityMismatch
    /// The device does not have the control, or the firmware does not allow diverting it.
    case controlUnavailable
    /// The control was not in its native state before the run.
    case unexpectedOriginalState(ControlReporting)
    /// The journal is unreadable or still holds records; resolve recovery first.
    case journalNotClean
    /// The recovery record could not be stored, so nothing was sent.
    case journalUnavailable
    /// Cancelled before anything was sent.
    case cancelled
    /// The device did not answer before anything was sent.
    case deviceUnavailable
}

/// The result of one run.
public enum ExperimentOutcome: Hashable, Sendable {
    /// Diverted, verified, restored, verified; the journal is clean.
    case completed
    /// Stopped before the device could have changed.
    case aborted(ExperimentAbort)
    /// The divert failed (or its result is unknown) and recovery verified the control native again.
    case divertFailedAndRecovered(DeviceConfigurationError)
    /// Restoration could not be verified; the recovery record is kept for retry.
    case recoveryPending(RestorationReport)
}

/// What the harness did, step by step.
public struct ExperimentReport: Hashable, Sendable {
    /// One recorded step.
    public enum Step: Hashable, Sendable {
        case authorized
        case transportChecked
        case identityVerified
        case originalRead(ControlReporting)
        case diverted
        case restoreAttempted(complete: Bool)
        case finalRead(ControlReporting)
    }

    /// The outcome.
    public var outcome: ExperimentOutcome
    /// The steps that ran, in order.
    public var steps: [Step]
}

/// Runs one approved temporary divert and its exact restoration on one device.
///
/// Order: redeem the token → Bluetooth only → approved model and expected unit →
/// journal clean → control divertable and native → (transaction) durable record,
/// one `0x03` write, read-back → exact restore with read-back, record removed only
/// once verified → independent final read.
///
/// Once the write may have reached the device — including a timeout, which is never
/// assumed to have failed — recovery always runs, shielded from cancellation.
public struct SingleUseDivertExperiment<Device: HIDPPRequestPerforming>: Sendable {
    private let transaction: ControlDivertTransaction<Device>
    private let transport: TransportType
    private let session: ExperimentSession

    /// Creates a harness for one connected device.
    ///
    /// - Parameters:
    ///   - transport: How the device is attached.
    ///   - session: The session that issued the token.
    public init(
        connection: Device,
        target: ConfigurableDevice,
        transport: TransportType,
        ledger: RestorationLedger,
        session: ExperimentSession,
        timeout: Duration? = nil
    ) {
        transaction = ControlDivertTransaction(
            connection: connection,
            target: target,
            ledger: ledger,
            authorization: .enabled,
            timeout: timeout
        )
        self.transport = transport
        self.session = session
    }

    /// Runs the operation the token permits.
    public func run(_ token: ExperimentAuthorization) async -> ExperimentReport {
        var report = ExperimentReport(outcome: .completed, steps: [])
        let control: ReprogrammableControl
        do {
            control = try await preflight(token, into: &report)
        } catch {
            report.outcome = .aborted(error)
            return report
        }
        guard !Task.isCancelled else {
            report.outcome = .aborted(.cancelled)
            return report
        }
        do {
            try await transaction.divert(control, with: token.operation.command)
            report.steps.append(.diverted)
        } catch {
            return await recover(after: error, into: report)
        }
        return await restore(into: report)
    }

    // MARK: - Steps

    private func preflight(
        _ token: ExperimentAuthorization,
        into report: inout ExperimentReport
    ) async throws(ExperimentAbort) -> ReprogrammableControl {
        guard await session.redeem(token) else { throw .notAuthorized }
        report.steps.append(.authorized)
        guard !Task.isCancelled else { throw .cancelled }
        guard transport == .bluetoothLowEnergy || transport == .bluetoothClassic else { throw .notBluetooth }
        report.steps.append(.transportChecked)
        let target = transaction.target
        guard token.operation.approves(target.physical.model), target.physical.unit == token.expectedUnit else {
            throw .identityMismatch
        }
        do {
            try await transaction.verifyIdentity()
        } catch {
            throw .identityMismatch
        }
        report.steps.append(.identityVerified)
        let ledger = transaction.ledger
        guard await ledger.corruption == nil, await ledger.pendingEntryCount == 0 else { throw .journalNotClean }
        let controls: [ReprogrammableControl]
        do {
            controls = try await transaction.controls()
        } catch {
            throw .deviceUnavailable
        }
        guard
            let control = controls.first(where: { $0.control == token.operation.control }),
            control.flags.contains(.divertable),
            let reporting = control.reporting
        else { throw .controlUnavailable }
        report.steps.append(.originalRead(reporting))
        guard reporting.isNative else { throw .unexpectedOriginalState(reporting) }
        return control
    }

    private func recover(after error: DeviceConfigurationError, into report: ExperimentReport) async -> ExperimentReport
    {
        var report = report
        if case .journalUnavailable = error {
            report.outcome = .aborted(.journalUnavailable)
            return report
        }
        // Any other failure may follow a write that reached the device (a timeout is
        // never assumed to have failed), or leaves a record behind: always recover.
        let restored = await restoreShielded()
        report.steps.append(.restoreAttempted(complete: restored.isComplete))
        if let final = await finalRead() { report.steps.append(.finalRead(final)) }
        guard restored.isComplete, await transaction.ledger.pendingEntryCount == 0 else {
            report.outcome = .recoveryPending(restored)
            return report
        }
        report.outcome = error == .cancelled ? .aborted(.cancelled) : .divertFailedAndRecovered(error)
        return report
    }

    private func restore(into report: ExperimentReport) async -> ExperimentReport {
        var report = report
        let restored = await restoreShielded()
        report.steps.append(.restoreAttempted(complete: restored.isComplete))
        let final = await finalRead()
        if let final { report.steps.append(.finalRead(final)) }
        let clean = await transaction.ledger.pendingEntryCount == 0
        report.outcome =
            restored.isComplete && clean && final?.isNative == true ? .completed : .recoveryPending(restored)
        return report
    }

    /// Restores in an unstructured task so the caller's cancellation cannot abort it.
    private func restoreShielded() async -> RestorationReport {
        let transaction = transaction
        return await Task { await transaction.restoreAll() }.value
    }

    private func finalRead() async -> ControlReporting? {
        let transaction = transaction
        let control = ExperimentOperation.mxMaster3SGestureDivertOnce.control
        return await Task { try? await transaction.read(control) }.value
    }
}
