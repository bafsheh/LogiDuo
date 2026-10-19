public import LogiDuoDomain

/// The controls LogiDuo may divert, and therefore the only controls an emergency
/// reset may touch.
public enum ManagedControls {
    /// Gesture button, mode shift button and the virtual gesture button.
    public static let all: Set<UInt16> = [0x00C3, 0x00C4, 0x00D7]
    /// Controls never written under any circumstance (primary and secondary buttons).
    public static let protected: Set<UInt16> = [0x0050, 0x0051]
}

/// What an emergency reset would do, computed from a read-only inspection of the
/// device. Nothing is changed until the person confirms this exact plan.
public struct EmergencyResetPlan: Hashable, Sendable {
    /// Why a managed control will be left alone.
    public enum SkipReason: Hashable, Sendable {
        /// The firmware does not allow diverting it.
        case notDivertable
        /// It is persistently diverted: a stored setting LogiDuo never creates or changes.
        case persistentlyDiverted
        /// It is remapped to another control: not LogiDuo's doing.
        case remapped(to: UInt16)
        /// Its reporting flags contain bits LogiDuo does not understand.
        case unexpectedState(UInt16)
    }

    /// What will happen to one control.
    public enum Disposition: Hashable, Sendable {
        /// Temporarily diverted; the command that will return it to native reporting.
        case reset(ReportingCommand)
        /// Already native; nothing will be written.
        case alreadyNative
        /// Left alone.
        case skipped(SkipReason)
    }

    /// One managed control present on the device.
    public struct Item: Hashable, Sendable {
        /// The control identifier.
        public let control: UInt16
        /// The state read during planning.
        public let observed: ControlReporting
        /// What will happen.
        public let disposition: Disposition
    }

    /// The device, with the physical identity verified while planning.
    public let device: ConfigurableDevice
    /// Every managed control the device has, in identifier order.
    public let items: [Item]
    /// Whether the journal was unreadable when planning (shown, never discarded).
    public let journalCorrupted: Bool
    let nonce: UInt64

    /// The controls that will be written.
    public var changes: [Item] {
        items.filter { item in
            if case .reset = item.disposition { return true }
            return false
        }
    }
}

/// The person's explicit confirmation of one specific plan.
public struct EmergencyResetConfirmation: Hashable, Sendable {
    let plan: EmergencyResetPlan

    /// Creates a confirmation. Call only from an explicit user action on a screen that
    /// showed `plan`'s device and affected controls.
    public init(userConfirmed plan: EmergencyResetPlan) {
        self.plan = plan
    }
}

/// The outcome of an emergency reset, per control.
public struct EmergencyResetReport: Hashable, Sendable {
    /// What happened to one control.
    public enum Outcome: Hashable, Sendable {
        /// Undiverted and verified native by read-back.
        case reset
        /// Was already native; nothing written.
        case alreadyNative
        /// Left alone as planned.
        case skipped(EmergencyResetPlan.SkipReason)
        /// Its state changed after planning, so it was not written.
        case stateChanged
        /// The write or the read-back failed.
        case failed(DeviceConfigurationError)
    }

    /// Why nothing was written at all, if so.
    public var blocked: DeviceConfigurationError?
    /// Each planned control's outcome.
    public var outcomes: [UInt16: Outcome] = [:]
    /// A journal save that failed while recording a confirmed restore.
    public var journalError: RestorationJournalStoreError?

    /// Whether every planned reset completed and was verified.
    public var isComplete: Bool {
        blocked == nil && journalError == nil
            && outcomes.values.allSatisfy { outcome in
                switch outcome {
                case .reset, .alreadyNative, .skipped: true
                case .stateChanged, .failed: false
                }
            }
    }
}

/// Manual recovery for one device, independent of remapping, the event tap and
/// gesture recognition.
///
/// * ``exactRestore()`` undoes exactly what valid recovery records describe and
///   verifies each control by reading it back. It refuses a corrupted journal.
/// * ``planEmergencyReset()`` (read-only) and ``performEmergencyReset(_:confirmation:)``
///   return LogiDuo's managed controls to native reporting when records are missing
///   or unreadable. The reset needs the person's confirmation of the exact plan,
///   re-verifies the physical identity, never touches protected, persistently
///   diverted, remapped or unrelated controls, never resets the device, and never
///   discards a recovery record it did not verify.
public struct DeviceRecovery<Device: HIDPPRequestPerforming>: Sendable {
    private let transaction: ControlDivertTransaction<Device>

    /// Creates a recovery for one connected device.
    public init(
        connection: Device,
        target: ConfigurableDevice,
        ledger: RestorationLedger,
        authorization: DeviceWriteAuthorization,
        timeout: Duration? = nil
    ) {
        transaction = ControlDivertTransaction(
            connection: connection,
            target: target,
            ledger: ledger,
            authorization: authorization,
            timeout: timeout
        )
    }

    /// The device this recovery works on.
    public var target: ConfigurableDevice { transaction.target }

    /// Restores every valid recovery record of the device, verifying each.
    public func exactRestore() async -> RestorationReport {
        if let corruption = await transaction.ledger.corruption {
            var report = RestorationReport()
            report.journalError = corruption
            return report
        }
        return await transaction.restoreAll()
    }

    /// Inspects the device (read-only) and plans an emergency reset.
    /// - Throws: ``DeviceConfigurationError/identityMismatch`` when the physical identity
    ///   is unknown or different; no plan exists for an unverified device.
    public func planEmergencyReset() async throws(DeviceConfigurationError) -> EmergencyResetPlan {
        let ledger = transaction.ledger
        let identity = transaction.target.identity
        await ledger.beginExclusive(identity)
        do {
            try await transaction.verifyIdentity()
            let controls = try await transaction.controls()
            await ledger.endExclusive(identity)
            return EmergencyResetPlan(
                device: transaction.target,
                items: Self.items(controls),
                journalCorrupted: await ledger.corruption != nil,
                nonce: UInt64.random(in: .min ... .max)
            )
        } catch {
            await ledger.endExclusive(identity)
            throw error
        }
    }

    /// Performs a confirmed plan. Partial failures are reported per control.
    public func performEmergencyReset(
        _ plan: EmergencyResetPlan,
        confirmation: EmergencyResetConfirmation
    ) async -> EmergencyResetReport {
        guard confirmation.plan == plan, plan.device == transaction.target else {
            return EmergencyResetReport(blocked: .notConfirmed)
        }
        guard transaction.authorization.allowsDiversion else {
            return EmergencyResetReport(blocked: .writesNotAuthorized)
        }
        // Once confirmed, the reset runs to completion even if the caller is cancelled.
        let recovery = self
        return await Task {
            let ledger = recovery.transaction.ledger
            await ledger.beginExclusive(plan.device.identity)
            let report = await recovery.reset(plan)
            await ledger.endExclusive(plan.device.identity)
            return report
        }
        .value
    }

    // MARK: - Steps

    private func reset(_ plan: EmergencyResetPlan) async -> EmergencyResetReport {
        var report = EmergencyResetReport()
        do {
            try await transaction.verifyIdentity()
        } catch {
            report.blocked = error
            return report
        }
        for item in plan.items {
            report.outcomes[item.control] = await outcome(of: item)
            if report.outcomes[item.control] == .reset || report.outcomes[item.control] == .alreadyNative {
                await confirmRecord(of: item.control, into: &report)
            }
        }
        return report
    }

    private func outcome(of item: EmergencyResetPlan.Item) async -> EmergencyResetReport.Outcome {
        switch item.disposition {
        case .skipped(let reason):
            return .skipped(reason)
        case .alreadyNative, .reset:
            do {
                let current = try await transaction.read(item.control)
                guard current == item.observed else { return .stateChanged }
                guard case .reset = item.disposition else { return .alreadyNative }
                try await transaction.undivert(item.control, from: current)
                return .reset
            } catch {
                return .failed(error)
            }
        }
    }

    /// A control now verified native fulfils a valid record whose original is native.
    private func confirmRecord(of control: UInt16, into report: inout EmergencyResetReport) async {
        let ledger = transaction.ledger
        let identity = transaction.target.identity
        let setting = RestorableSetting.controlReporting(DeviceControlID(rawValue: control))
        guard
            await ledger.original(of: setting, on: identity) == .controlReporting(diverted: false, rawXYDiverted: false)
        else { return }
        do {
            try await ledger.confirmRestored(setting, on: identity)
        } catch {
            report.journalError = error
        }
    }

    static func items(_ controls: [ReprogrammableControl]) -> [EmergencyResetPlan.Item] {
        controls
            .filter { ManagedControls.all.contains($0.control) && !ManagedControls.protected.contains($0.control) }
            .sorted { $0.control < $1.control }
            .compactMap { control in
                guard let reporting = control.reporting else { return nil }
                return EmergencyResetPlan.Item(
                    control: control.control,
                    observed: reporting,
                    disposition: disposition(of: control, reporting)
                )
            }
    }

    private static func disposition(
        of control: ReprogrammableControl,
        _ reporting: ControlReporting
    ) -> EmergencyResetPlan.Disposition {
        if reporting.isNative { return .alreadyNative }
        guard control.flags.contains(.divertable) else { return .skipped(.notDivertable) }
        if reporting.isPersistentlyDiverted { return .skipped(.persistentlyDiverted) }
        if reporting.remappedTo != control.control { return .skipped(.remapped(to: reporting.remappedTo)) }
        let command = ReportingCommand.undivert(from: reporting)
        let known: Set<UInt16> = control.flags.contains(.rawXY) ? [0x0001, 0x0011] : [0x0001]
        guard known.contains(reporting.flags) else { return .skipped(.unexpectedState(reporting.flags)) }
        return .reset(command)
    }
}
