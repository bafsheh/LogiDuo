import Foundation

/// A transport wrapper that only lets documented read-only HID++ requests through.
///
/// Every outbound report is decoded and checked against ``allowedFunctions``.
/// Requests to the Root feature (index 0) are recognised directly; any other
/// feature index is allowed only after the guard has *observed* a Root
/// `getFeature` reply mapping that index to an allow-listed feature on the
/// same device. Anything else — unknown indexes, HID++ 1.0 register access,
/// functions not on the list — is refused with
/// ``HIDPPTransportError/blockedByPolicy`` and never reaches the device.
///
/// With `allowingDiversion`, one write is added: ReprogControlsV4 `setCidReporting`,
/// only for a control LogiDuo diverts (``DivertedControlsDecoder/buttons``), only with a
/// ``ReportingCommand`` flags byte (no persist bits) and only with remapping left unchanged.
public final class ReadOnlyTransportGuard: HIDPPTransport, @unchecked Sendable {  // Invariant: guarded by `lock`.
    /// Read-only ("get") functions per feature, from the HID++ 2.0 feature specifications.
    public static let allowedFunctions: [FeatureID: Set<UInt8>] = [
        .root: [0, 1],  // getFeature, getProtocolVersion
        .featureSet: [0, 1],  // getCount, getFeatureID
        .deviceInformation: [0, 1],  // getDeviceInfo, getFwInfo (serial number excluded)
        .deviceName: [0, 1, 2],  // getDeviceNameCount, getDeviceName, getDeviceType
        .batteryStatus: [0],  // getBatteryLevelStatus
        .unifiedBattery: [0, 1],  // getCapabilities, getStatus
        .reprogControlsV4: [0, 1, 2],  // getCount, getCidInfo, getCidReporting (setCidReporting excluded)
        .adjustableDPI: [0, 1, 2],  // getSensorCount, getSensorDpiList, getSensorDpi (setSensorDpi excluded)
        .smartShift: [0],  // getRatchetControlMode (setRatchetControlMode excluded)
        .smartShiftEnhanced: [0, 1],  // getCapabilities, getRatchetControlMode (set excluded)
        .hiResWheel: [0, 1, 3],  // getWheelCapability, getWheelMode, getRatchetSwitchState (setWheelMode excluded)
        .thumbwheel: [0, 1],  // getThumbwheelInfo, getThumbwheelStatus (setThumbwheelReporting excluded)
        .changeHost: [0],  // getHostInfo (setCurrentHost excluded: it would switch the device away)
        .backlight2: [0],  // getBacklightConfig (setBacklightConfig excluded)
        .fnInversionMultiHost: [0],  // getFnInversion(host) (setFnInversion excluded)
        .disableKeys: [0, 1],  // getCapabilities, getDisabledKeys (setDisabledKeys excluded)
    ]

    /// ReprogControlsV4 `setCidReporting`.
    static let setControlReporting: UInt8 = 3

    private struct Lookup: Hashable {
        let device: UInt8
        let softwareID: UInt8
    }

    private struct Slot: Hashable {
        let device: UInt8
        let index: UInt8
    }

    /// The inner transport's framing.
    public let framing: HIDPPFraming
    /// The inner transport's events, observed for Root replies on the way through.
    public let events: AsyncStream<HIDPPTransportEvent>

    private let inner: any HIDPPTransport
    private let allowsDiversion: Bool
    private let lock = NSLock()
    private var pendingLookups: [Lookup: FeatureID] = [:]
    private var features: [Slot: FeatureID] = [:]
    private var refused = 0
    private var relay: Task<Void, Never>?

    /// Wraps `inner`; with `allowingDiversion`, temporary button diverts also pass (see the type's documentation).
    public init(wrapping inner: any HIDPPTransport, allowingDiversion: Bool = false) {
        self.inner = inner
        self.allowsDiversion = allowingDiversion
        self.framing = inner.framing
        let (events, sink) = AsyncStream.makeStream(of: HIDPPTransportEvent.self)
        self.events = events
        let source = inner.events
        relay = Task { [weak self] in
            for await event in source {
                self?.observe(event)
                sink.yield(event)
            }
            sink.finish()
        }
    }

    /// How many reports were refused.
    public var refusedReports: Int { lock.withLock { refused } }

    /// Sends `report` only if it is an allow-listed read.
    public func send(_ report: [UInt8]) async throws(HIDPPTransportError) {
        guard permit(report) else {
            lock.withLock { refused += 1 }
            throw .blockedByPolicy
        }
        try await inner.send(report)
    }

    /// Closes the inner transport.
    public func close() async {
        await inner.close()
        relay?.cancel()
    }

    private func permit(_ bytes: [UInt8]) -> Bool {
        guard
            let report = try? framing.decode(bytes),
            case .message(let request) = HIDPPInbound(report),
            !request.softwareID.isNotification
        else { return false }
        let function = request.function.rawValue
        return lock.withLock {
            let feature: FeatureID? =
                request.featureIndex == .root
                ? .root : features[Slot(device: request.deviceIndex.rawValue, index: request.featureIndex.rawValue)]
            guard let feature else { return false }
            if allowsDiversion, feature == .reprogControlsV4, function == Self.setControlReporting {
                return Self.isTemporaryDivert(request.parameters)
            }
            guard Self.allowedFunctions[feature]?.contains(function) == true else { return false }
            if feature == .root, function == 0 {
                let requested = FeatureID(rawValue: UInt16(request.parameters[0]) << 8 | UInt16(request.parameters[1]))
                pendingLookups[Lookup(device: request.deviceIndex.rawValue, softwareID: request.softwareID.rawValue)] =
                    requested
            }
            return true
        }
    }

    private func observe(_ event: HIDPPTransportEvent) {
        guard
            case .input(let bytes) = event,
            let report = try? framing.decode(bytes),
            case .message(let reply) = HIDPPInbound(report),
            reply.featureIndex == .root, reply.function.rawValue == 0
        else { return }
        let lookup = Lookup(device: reply.deviceIndex.rawValue, softwareID: reply.softwareID.rawValue)
        lock.withLock {
            guard let feature = pendingLookups.removeValue(forKey: lookup), reply.parameters[0] != 0 else { return }
            features[Slot(device: lookup.device, index: reply.parameters[0])] = feature
        }
    }

    /// `[cid hi, cid lo, flags, remap hi, remap lo, 0…]`: a managed control, a ``ReportingCommand``
    /// flags byte and nothing else (remap 0 leaves remapping unchanged).
    static func isTemporaryDivert(_ parameters: [UInt8]) -> Bool {
        guard parameters.count >= 5 else { return false }
        let control = UInt16(parameters[0]) << 8 | UInt16(parameters[1])
        return DivertedControlsDecoder.buttons[control] != nil
            && ReportingCommand.allCases.contains { $0.flagsByte == parameters[2] }
            && parameters[3...].allSatisfy { $0 == 0 }
    }
}

extension DeviceWriteAuthorization {
    /// `transport`, limited to the writes this authorization allows.
    public func limiting(_ transport: any HIDPPTransport) -> any HIDPPTransport {
        switch self {
        case .enabled: transport
        case .diversionOnly: ReadOnlyTransportGuard(wrapping: transport, allowingDiversion: true)
        case .disabled: ReadOnlyTransportGuard(wrapping: transport)
        }
    }
}
