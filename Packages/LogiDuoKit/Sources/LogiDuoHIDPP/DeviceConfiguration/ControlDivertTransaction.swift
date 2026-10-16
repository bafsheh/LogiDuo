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
    /// A HID++ request failed.
    case request(HIDPPRequestError)
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

/// Applies and undoes temporary control diversion with a durable recovery record.
///
/// Sequence for ``divert(_:change:)`` (steps 1–3 are the caller's: a connected
/// device, its identity, and a fresh control table):
/// 4. read the control's current reporting;
/// 5–6. record the original in the ledger, saved and verified durably — if that
///    fails nothing is written to the device;
/// 7. write one narrowly scoped change;
/// 8–9. read back and compare — on a mismatch the original is restored and the
///    error reported.
/// ``restoreAll()`` performs steps 10–12 for every pending entry of the device:
/// write the original, read back, and only then remove the entry.
///
/// Any failure leaves the journal entry in place, so restoration can be retried
/// on the next connection or launch. Restoring is idempotent.
public struct ControlDivertTransaction<Device: HIDPPRequestPerforming>: Sendable {
    private let device: Device
    private let identity: DeviceID
    private let featureIndex: FeatureIndex
    private let deviceIndex: DeviceIndex
    private let ledger: RestorationLedger
    private let timeout: Duration?

    /// Creates a transaction for one connected device.
    public init(
        device: Device,
        identity: DeviceID,
        featureIndex: FeatureIndex,
        deviceIndex: DeviceIndex,
        ledger: RestorationLedger,
        timeout: Duration? = nil
    ) {
        self.device = device
        self.identity = identity
        self.featureIndex = featureIndex
        self.deviceIndex = deviceIndex
        self.ledger = ledger
        self.timeout = timeout
    }

    /// Diverts `control` with `change`, recording how to undo it first.
    public func divert(_ control: ReprogrammableControl, change: ReportingChange) async throws(DeviceConfigurationError)
    {
        guard control.flags.contains(.divertable) else { throw .notDivertable(control.control) }
        let setting = RestorableSetting.controlReporting(DeviceControlID(rawValue: control.control))
        let current = try await read(control.control)
        if await ledger.original(of: setting, on: identity) == nil {
            guard current.isNative else { throw .foreignState(control.control) }
            do {
                try await ledger.record(
                    setting,
                    on: identity,
                    original: .controlReporting(diverted: current.isDiverted, rawXYDiverted: current.isRawXYDiverted)
                )
            } catch {
                throw .journalUnavailable(error)
            }
        }
        try await write(control.control, change)
        guard change.matches(try await read(control.control)) else {
            _ = await restoreAll()
            throw .verificationFailed(control.control)
        }
    }

    /// Restores every pending setting of this device, verifying each.
    public func restoreAll() async -> RestorationReport {
        var report = RestorationReport()
        for entry in await ledger.pending(for: identity) {
            do {
                try await restore(entry)
                report.restored.append(entry.setting)
                do {
                    try await ledger.confirmRestored(entry.setting, on: identity)
                } catch {
                    report.journalError = error
                }
            } catch {
                report.failed[entry.setting] = error
                do {
                    try await ledger.recordFailure(entry.setting, on: identity)
                } catch {
                    report.journalError = error
                }
            }
        }
        return report
    }

    private func restore(_ entry: RestorationEntry) async throws(DeviceConfigurationError) {
        guard
            case .controlReporting(let control) = entry.setting,
            case .controlReporting(let diverted, let rawXY) = entry.original
        else { throw .unsupportedSetting(entry.setting) }
        let original = ReportingChange(divert: diverted, rawXY: rawXY)
        try await write(control.rawValue, original)
        guard original.matches(try await read(control.rawValue)) else {
            throw .restorationIncomplete(control.rawValue)
        }
    }

    private func read(_ control: UInt16) async throws(DeviceConfigurationError) -> ControlReporting {
        do {
            return try await ReprogControlsFeature.reporting(
                of: control,
                via: device,
                index: featureIndex,
                deviceIndex: deviceIndex,
                timeout: timeout
            )
        } catch {
            throw .request(error)
        }
    }

    private func write(_ control: UInt16, _ change: ReportingChange) async throws(DeviceConfigurationError) {
        do {
            try await ReprogControlsFeature.setReporting(
                of: control,
                to: change,
                via: device,
                index: featureIndex,
                deviceIndex: deviceIndex,
                timeout: timeout
            )
        } catch {
            throw .request(error)
        }
    }
}
