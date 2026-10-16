public import LogiDuoDomain

/// Why a device configuration step did not complete.
public enum DeviceConfigurationError: Error, Hashable, Sendable {
    /// The control cannot be diverted on this device.
    case notDivertable(UInt16)
    /// The control is already diverted or remapped by something other than LogiDuo; LogiDuo will not take it over.
    case foreignState(UInt16)
    /// The recovery record could not be stored durably, so the device was not changed.
    case journalUnavailable(RestorationJournalStoreError)
    /// The device reported a different state after the change.
    case verificationFailed(UInt16)
    /// Restoring did not reach the original state (entry kept for retry).
    case restorationIncomplete(UInt16)
    /// This kind of setting cannot be restored yet (entry kept).
    case unsupportedSetting(RestorableSetting)
    /// The requested command is not supported by the control (for example raw XY on a control without it).
    case unsupportedCombination(UInt16)
    /// The device's reply did not match the request (for example another control's identifier).
    case unexpectedResponse(UInt16)
    /// The connected device is not the expected physical device, or its identity cannot be read.
    case identityMismatch
    /// Device configuration writes are not enabled in this build or session.
    case writesNotAuthorized
    /// The operation was cancelled before changing the device.
    case cancelled
    /// The device has recovery records from an earlier run; restore it before configuring it again.
    case recoveryPending
    /// A destructive recovery step was attempted without the person's confirmation of that exact plan.
    case notConfirmed
    /// A HID++ request failed.
    case request(HIDPPRequestError)
}

/// Whether this build or session may send configuration writes to devices.
public enum DeviceWriteAuthorization: Hashable, Sendable {
    /// Writes are refused before anything is sent.
    case disabled
    /// Writes are allowed.
    case enabled
}

/// The outcome of restoring one device.
public struct RestorationReport: Hashable, Sendable {
    /// Settings restored and verified (and removed from the journal).
    public var restored: [RestorableSetting] = []
    /// Settings that could not be restored (still pending).
    public var failed: [RestorableSetting: DeviceConfigurationError] = [:]
    /// A journal save that failed while recording the outcome. The affected entries
    /// stay pending, so the (idempotent) restore runs again later.
    public var journalError: RestorationJournalStoreError?

    /// Whether every pending setting was restored and the journal updated.
    public var isComplete: Bool { failed.isEmpty && journalError == nil }
}

/// Where a device's configuration features live and who it must be.
public struct ConfigurableDevice: Hashable, Sendable {
    /// The logical identity (journal key source).
    public let identity: DeviceID
    /// The firmware identity every operation re-verifies.
    public let physical: PhysicalDeviceID
    /// The HID++ device index.
    public let deviceIndex: DeviceIndex
    /// ReprogControlsV4 feature index.
    public let reprogIndex: FeatureIndex
    /// DeviceInformation feature index (for identity verification).
    public let informationIndex: FeatureIndex

    /// Creates a description.
    public init(
        identity: DeviceID,
        physical: PhysicalDeviceID,
        deviceIndex: DeviceIndex,
        reprogIndex: FeatureIndex,
        informationIndex: FeatureIndex
    ) {
        self.identity = identity
        self.physical = physical
        self.deviceIndex = deviceIndex
        self.reprogIndex = reprogIndex
        self.informationIndex = informationIndex
    }
}

/// Applies and undoes temporary control diversion with a durable recovery record.
///
/// ``divert(_:with:)``, for one control:
/// 1. writes must be authorized; the command must be a divert the control supports;
/// 2. wait for exclusive access to the device (no concurrent divert or restore);
/// 3. re-verify the device's firmware identity (unit and model);
/// 4. read the control's current state; a state LogiDuo did not record must be native;
/// 5–6. record the exact original in the ledger, saved and verified durably;
/// 7. write one command (unless cancelled first);
/// 8–9. read back and compare — on a mismatch only this control is restored.
///
/// ``restoreAll()`` (steps 10–13), for every pending entry of the device: re-verify
/// identity, write the undivert command matching the current state, read back,
/// and only then remove the entry. Disconnects, timeouts, cancellation and
/// termination leave entries in place. Restoring is idempotent.
public struct ControlDivertTransaction<Device: HIDPPRequestPerforming>: Sendable {
    private let connection: Device
    let target: ConfigurableDevice
    let ledger: RestorationLedger
    let authorization: DeviceWriteAuthorization
    private let timeout: Duration?

    /// Creates a transaction for one connected device.
    public init(
        connection: Device,
        target: ConfigurableDevice,
        ledger: RestorationLedger,
        authorization: DeviceWriteAuthorization,
        timeout: Duration? = nil
    ) {
        self.connection = connection
        self.target = target
        self.ledger = ledger
        self.authorization = authorization
        self.timeout = timeout
    }

    /// Diverts `control` with `command`, recording how to undo it first.
    public func divert(
        _ control: ReprogrammableControl,
        with command: ReportingCommand
    ) async throws(DeviceConfigurationError) {
        guard authorization == .enabled else { throw .writesNotAuthorized }
        guard command.diverts else { throw .unsupportedCombination(control.control) }
        try command.validate(for: control)
        await ledger.beginExclusive(target.identity)
        do {
            try await divertExclusively(control.control, command)
            await ledger.endExclusive(target.identity)
        } catch {
            await ledger.endExclusive(target.identity)
            throw error
        }
    }

    /// Restores every pending setting of this device, verifying each.
    ///
    /// Runs to completion even if the calling task is cancelled: an interrupted
    /// restore would leave the device diverted.
    public func restoreAll() async -> RestorationReport {
        let transaction = self
        return await Task { await transaction.restoreAllNow() }.value
    }

    private func restoreAllNow() async -> RestorationReport {
        let pending = await ledger.pending(for: target.identity)
        guard !pending.isEmpty else { return RestorationReport() }
        guard authorization == .enabled else { return Self.failing(pending, .writesNotAuthorized) }
        await ledger.beginExclusive(target.identity)
        let report = await restoreExclusively()
        await ledger.endExclusive(target.identity)
        return report
    }

    // MARK: - Steps

    func restoreExclusively() async -> RestorationReport {
        do {
            try await verifyIdentity()
        } catch {
            return Self.failing(await ledger.pending(for: target.identity), error)
        }
        var report = RestorationReport()
        for entry in await ledger.pending(for: target.identity) {
            await restore(entry, into: &report)
        }
        return report
    }

    private func divertExclusively(
        _ control: UInt16,
        _ command: ReportingCommand
    ) async throws(DeviceConfigurationError) {
        guard await !ledger.hasInheritedEntries(target.identity) else { throw .recoveryPending }
        try await verifyIdentity()
        let setting = RestorableSetting.controlReporting(DeviceControlID(rawValue: control))
        let current = try await read(control)
        if await ledger.original(of: setting, on: target.identity) == nil {
            guard current.isNative else { throw .foreignState(control) }
            do {
                try await ledger.record(
                    setting,
                    on: target.identity,
                    original: .controlReporting(diverted: false, rawXYDiverted: false)
                )
            } catch {
                throw .journalUnavailable(error)
            }
        }
        guard !Task.isCancelled else { throw .cancelled }
        try await ReprogControlsFeature.send(
            command,
            to: control,
            via: connection,
            index: target.reprogIndex,
            deviceIndex: target.deviceIndex,
            timeout: timeout
        )
        guard command.isSatisfied(by: try await read(control)) else {
            if let entry = await ledger.pending(for: target.identity).first(where: { $0.setting == setting }) {
                // Shielded from cancellation, like every restore.
                let transaction = self
                await Task {
                    var ignored = RestorationReport()
                    await transaction.restore(entry, into: &ignored)
                }
                .value
            }
            throw .verificationFailed(control)
        }
    }

    private func restore(_ entry: RestorationEntry, into report: inout RestorationReport) async {
        do {
            try await restoreToNative(entry)
            report.restored.append(entry.setting)
            do {
                try await ledger.confirmRestored(entry.setting, on: target.identity)
            } catch {
                report.journalError = error
            }
        } catch {
            report.failed[entry.setting] = error
            do {
                try await ledger.recordFailure(entry.setting, on: target.identity)
            } catch {
                report.journalError = error
            }
        }
    }

    private func restoreToNative(_ entry: RestorationEntry) async throws(DeviceConfigurationError) {
        guard
            case .controlReporting(let control) = entry.setting,
            entry.original == .controlReporting(diverted: false, rawXYDiverted: false)
        else { throw .unsupportedSetting(entry.setting) }
        let current = try await read(control.rawValue)
        if current.isNative { return }
        guard current.remappedTo == control.rawValue, !current.isPersistentlyDiverted else {
            throw .foreignState(control.rawValue)
        }
        try await undivert(control.rawValue, from: current)
    }

    /// Writes the undivert matching `current` and verifies the read-back.
    func undivert(_ control: UInt16, from current: ControlReporting) async throws(DeviceConfigurationError) {
        let command = ReportingCommand.undivert(from: current)
        try await ReprogControlsFeature.send(
            command,
            to: control,
            via: connection,
            index: target.reprogIndex,
            deviceIndex: target.deviceIndex,
            timeout: timeout
        )
        guard command.isSatisfied(by: try await read(control)) else { throw .restorationIncomplete(control) }
    }

    /// Reads every control with its capabilities and reporting state.
    func controls() async throws(DeviceConfigurationError) -> [ReprogrammableControl] {
        do {
            return try await ReprogControlsFeature.controls(
                via: connection,
                index: target.reprogIndex,
                deviceIndex: target.deviceIndex,
                timeout: timeout
            )
        } catch {
            throw .request(error)
        }
    }

    func verifyIdentity() async throws(DeviceConfigurationError) {
        let information: DeviceInformation
        do {
            information = try await DeviceInformationFeature.information(
                via: connection,
                index: target.informationIndex,
                deviceIndex: target.deviceIndex,
                timeout: timeout
            )
        } catch {
            throw .identityMismatch
        }
        guard information.physicalID == target.physical else { throw .identityMismatch }
    }

    func read(_ control: UInt16) async throws(DeviceConfigurationError) -> ControlReporting {
        do {
            return try await ReprogControlsFeature.reporting(
                of: control,
                via: connection,
                index: target.reprogIndex,
                deviceIndex: target.deviceIndex,
                timeout: timeout
            )
        } catch {
            throw .request(error)
        }
    }

    private static func failing(_ entries: [RestorationEntry], _ error: DeviceConfigurationError) -> RestorationReport {
        var report = RestorationReport()
        for entry in entries { report.failed[entry.setting] = error }
        return report
    }
}
