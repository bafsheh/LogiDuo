import Foundation
public import LogiDuoDomain

/// The recovery operations of one connected device.
public protocol RecoverySession: Sendable {
    /// The device, with its verified physical identity.
    var target: ConfigurableDevice { get }
    /// See ``DeviceRecovery/exactRestore()``.
    func exactRestore() async -> RestorationReport
    /// See ``DeviceRecovery/planEmergencyReset()``.
    func planEmergencyReset() async throws(DeviceConfigurationError) -> EmergencyResetPlan
    /// See ``DeviceRecovery/performEmergencyReset(_:confirmation:)``.
    func performEmergencyReset(
        _ plan: EmergencyResetPlan,
        confirmation: EmergencyResetConfirmation
    ) async -> EmergencyResetReport
}

extension DeviceRecovery: RecoverySession {}

/// A connected device recovery can use.
public struct RecoveryEndpoint: Sendable {
    /// The name the device reports.
    public let name: String
    /// Its recovery operations.
    public let session: any RecoverySession
    /// Releases the connection.
    public let close: @Sendable () async -> Void

    /// Creates an endpoint.
    public init(name: String, session: any RecoverySession, close: @escaping @Sendable () async -> Void = {}) {
        self.name = name
        self.session = session
        self.close = close
    }
}

/// Finds what recovery needs on a device, using read-only requests only.
public enum RecoveryDeviceLocator {
    /// What was found.
    public struct Located: Hashable, Sendable {
        /// Feature locations and the verified physical identity.
        public let target: ConfigurableDevice
        /// The reported name, or a generic one.
        public let name: String
    }

    /// Locates ReprogControlsV4 and DeviceInformation and reads the physical identity.
    /// A device without a firmware identity cannot be recovered: identity cannot be verified.
    public static func locate(
        via device: some HIDPPRequestPerforming,
        deviceIndex: DeviceIndex,
        timeout: Duration?
    ) async -> Result<Located, RecoveryBlock> {
        do {
            guard
                let reprog = try await RootFeature.location(
                    of: .reprogControlsV4,
                    via: device,
                    device: deviceIndex,
                    timeout: timeout
                )
            else { return .failure(.unsupportedDevice) }
            guard
                let information = try await RootFeature.location(
                    of: .deviceInformation,
                    via: device,
                    device: deviceIndex,
                    timeout: timeout
                ),
                let physical = try? await DeviceInformationFeature.information(
                    via: device,
                    index: information.index,
                    deviceIndex: deviceIndex,
                    timeout: timeout
                ).physicalID
            else { return .failure(.identityUnverified) }
            let target = ConfigurableDevice(
                identity: DeviceID(physical: physical),
                physical: physical,
                deviceIndex: deviceIndex,
                reprogIndex: reprog.index,
                informationIndex: information.index
            )
            return .success(
                Located(target: target, name: await name(via: device, deviceIndex: deviceIndex, timeout: timeout))
            )
        } catch {
            return .failure(.deviceUnavailable)
        }
    }

    private static func name(
        via device: some HIDPPRequestPerforming,
        deviceIndex: DeviceIndex,
        timeout: Duration?
    ) async -> String {
        guard
            let location = try? await RootFeature.location(
                of: .deviceName,
                via: device,
                device: deviceIndex,
                timeout: timeout
            ),
            let name = try? await DeviceNameFeature.name(
                via: device,
                index: location.index,
                deviceIndex: deviceIndex,
                timeout: timeout
            ),
            !name.isEmpty
        else { return "Logitech device" }
        return name
    }
}

/// ``DeviceRecoveryServicing`` over HID++ devices and the restoration ledger.
///
/// Proposals are kept here and are single-use: performing one turns the
/// person's confirmation of the exact plan they saw into an
/// ``EmergencyResetConfirmation``. An unknown, stale or reused proposal is refused.
public actor HIDPPRecoveryService: DeviceRecoveryServicing {
    /// Connects to the devices present right now.
    public typealias Connect = @Sendable () async -> [RecoveryEndpoint]

    private let ledger: RestorationLedger
    private let connect: Connect
    private var endpoints: [DeviceID: RecoveryEndpoint] = [:]
    private var proposals: [UUID: (device: DeviceID, plan: EmergencyResetPlan)] = [:]
    private var loaded = false

    /// Creates a service over `ledger`, loading it on first use if needed.
    public init(ledger: RestorationLedger, connect: @escaping Connect) {
        self.ledger = ledger
        self.connect = connect
    }

    /// The journal's status.
    public func journalStatus() async -> RecoveryJournalStatus {
        await loadOnce()
        if await ledger.corruption != nil { return .corrupted }
        let count = await ledger.pendingEntryCount
        return count == 0 ? .clean : .pending(entries: count)
    }

    /// Connected devices with a verified physical identity.
    public func devices() async -> [RecoveryDevice] {
        await loadOnce()
        for endpoint in endpoints.values { await endpoint.close() }
        endpoints = [:]
        proposals = [:]
        for endpoint in await connect() {
            endpoints[endpoint.session.target.identity] = endpoint
        }
        var devices: [RecoveryDevice] = []
        for (id, endpoint) in endpoints {
            devices.append(
                RecoveryDevice(
                    id: id,
                    name: endpoint.name,
                    model: endpoint.session.target.physical.model,
                    pendingRecords: await ledger.pending(for: id).count
                )
            )
        }
        return devices.sorted { $0.name < $1.name }
    }

    /// Undoes exactly what valid records describe.
    public func exactRestore(_ device: DeviceID) async -> RecoveryResult {
        guard let endpoint = endpoints[device] else { return RecoveryResult(blocked: .deviceUnavailable) }
        return Self.result(of: await endpoint.session.exactRestore())
    }

    /// Plans an emergency reset without changing anything.
    public func proposeEmergencyReset(_ device: DeviceID) async -> Result<EmergencyResetProposal, RecoveryBlock> {
        guard let endpoint = endpoints[device] else { return .failure(.deviceUnavailable) }
        let plan: EmergencyResetPlan
        do {
            plan = try await endpoint.session.planEmergencyReset()
        } catch {
            return .failure(Self.block(for: error))
        }
        guard !plan.items.isEmpty else { return .failure(.unsupportedDevice) }
        let proposal = EmergencyResetProposal(
            id: UUID(),
            device: RecoveryDevice(
                id: device,
                name: endpoint.name,
                model: plan.device.physical.model,
                pendingRecords: await ledger.pending(for: device).count
            ),
            controls: plan.items.map { item in
                RecoveryControl(control: DeviceControlID(rawValue: item.control), plan: Self.plan(for: item))
            },
            journalCorrupted: plan.journalCorrupted
        )
        proposals = [proposal.id: (device, plan)]
        return .success(proposal)
    }

    /// Performs a confirmed proposal once.
    public func performEmergencyReset(userConfirmed proposal: EmergencyResetProposal) async -> RecoveryResult {
        guard let stored = proposals.removeValue(forKey: proposal.id), stored.device == proposal.device.id else {
            return RecoveryResult(blocked: .notConfirmed)
        }
        guard let endpoint = endpoints[stored.device] else { return RecoveryResult(blocked: .deviceUnavailable) }
        let report = await endpoint.session.performEmergencyReset(
            stored.plan,
            confirmation: EmergencyResetConfirmation(userConfirmed: stored.plan)
        )
        return Self.result(of: report)
    }

    /// Records that the person has seen the corrupted-journal notice.
    public func acknowledgeCorruption() async {
        await ledger.acknowledgeCorruption()
    }

    private func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        _ = await ledger.load()
    }

    // MARK: - Mapping

    static func block(for error: DeviceConfigurationError) -> RecoveryBlock {
        switch error {
        case .identityMismatch: .identityUnverified
        case .writesNotAuthorized: .writesDisabled
        case .notConfirmed: .notConfirmed
        case .journalUnavailable(.corrupted): .journalCorrupted
        default: .deviceUnavailable
        }
    }

    static func result(of report: RestorationReport) -> RecoveryResult {
        if case .corrupted? = report.journalError { return RecoveryResult(blocked: .journalCorrupted) }
        let errors = Set(report.failed.values)
        if report.restored.isEmpty, errors.count == 1, let only = errors.first,
            only == .writesNotAuthorized || only == .identityMismatch
        {
            return RecoveryResult(blocked: block(for: only))
        }
        var result = RecoveryResult(journalSaveFailed: report.journalError != nil)
        for setting in report.restored {
            if case .controlReporting(let control) = setting { result.outcomes[control] = .restored }
        }
        for setting in report.failed.keys {
            if case .controlReporting(let control) = setting {
                result.outcomes[control] = .failed
            } else {
                result.otherFailures += 1
            }
        }
        return result
    }

    static func result(of report: EmergencyResetReport) -> RecoveryResult {
        if let blocked = report.blocked { return RecoveryResult(blocked: block(for: blocked)) }
        var result = RecoveryResult(journalSaveFailed: report.journalError != nil)
        for (control, outcome) in report.outcomes {
            result.outcomes[DeviceControlID(rawValue: control)] =
                switch outcome {
                case .reset: .restored
                case .alreadyNative: .alreadyNative
                case .skipped: .skipped
                case .stateChanged: .changedSincePlanning
                case .failed: .failed
                }
        }
        return result
    }

    static func plan(for item: EmergencyResetPlan.Item) -> RecoveryControlPlan {
        switch item.disposition {
        case .reset: .willReset
        case .alreadyNative: .alreadyNative
        case .skipped(.persistentlyDiverted): .skippedPersistent
        case .skipped(.remapped): .skippedRemapped
        case .skipped(.notDivertable): .skippedNotDivertable
        case .skipped(.unexpectedState): .skippedUnexpected
        }
    }
}
