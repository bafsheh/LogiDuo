import LogiDuoDomain
import LogiDuoHIDPP

/// Everything about a device except its identity, which the directory assigns.
struct DeviceDraft: Hashable, Sendable {
    var name: String
    var category: DeviceCategory
    var transport: TransportType
    var link: DeviceLinkState
    var battery: BatteryStatus?
    var firmwareVersion: String?
    var model: ModelID?
    var features: DeviceFeatures
    var resolution: ResolutionState?
    var smartShift: SmartShiftMode?
    var keyboard: KeyboardState?

    func snapshot(id: DeviceID) -> DeviceSnapshot {
        DeviceSnapshot(
            id: id,
            name: name,
            category: category,
            transport: transport,
            link: link,
            battery: battery,
            firmwareVersion: firmwareVersion,
            model: model,
            features: features,
            resolution: resolution,
            smartShift: smartShift,
            keyboard: keyboard
        )
    }
}

/// What a session reports to its directory.
enum DeviceSessionUpdate: Sendable {
    /// The device was read after connecting.
    case identified(DeviceObservation, DeviceDraft)
    /// The connection state changed.
    case link(TransportEndpoint, DeviceLinkState)
    /// A new battery reading.
    case battery(TransportEndpoint, BatteryStatus?)
}

/// One device endpoint: its connection, and reading the device whenever it connects.
/// Setting changes live in `DeviceSession+Settings.swift`.
actor DeviceSession<SessionClock: Clock> where SessionClock.Duration == Duration {
    typealias Publish = @Sendable (DeviceSessionUpdate) async -> Void

    nonisolated let endpoint: TransportEndpoint
    let connection: HIDPPConnection<SessionClock>
    let deviceIndex: DeviceIndex
    var resolutionRange: ResolutionRange?
    private let fallbackName: String
    private let product: ProductID
    private let publish: Publish
    private var observer: Task<Void, Never>?
    private var batteryFeature: FeatureID?

    init(
        endpoint: TransportEndpoint,
        fallbackName: String,
        product: ProductID,
        deviceIndex: DeviceIndex,
        clock: SessionClock,
        openTransport: @escaping HIDPPConnection<SessionClock>.TransportFactory,
        publish: @escaping Publish
    ) {
        self.endpoint = endpoint
        self.fallbackName = fallbackName
        self.product = product
        self.publish = publish
        self.deviceIndex = deviceIndex
        connection = HIDPPConnection(
            deviceIndex: deviceIndex,
            configuration: HIDPPConnectionConfiguration(retryPolicy: .standard),
            clock: clock,
            openTransport: openTransport,
            handshake: { channel, index, timeout async throws(HIDPPRequestError) in
                try await RootFeature.handshake(channel, index, timeout)
            }
        )
    }

    /// Starts following the connection and connects.
    func start() async {
        let states = connection.states
        observer = Task { [weak self] in
            for await state in states {
                await self?.handle(state)
            }
        }
        await connection.connect()
    }

    /// Re-reads the battery while connected.
    func refresh() async {
        guard await connection.state == .connected, let batteryFeature, let index = await index(of: batteryFeature),
            let reading = try? await BatteryFeature.reading(
                feature: batteryFeature,
                via: connection,
                index: index,
                deviceIndex: deviceIndex
            )
        else { return }
        await publish(.battery(endpoint, DeviceSnapshotMapper.battery(reading)))
    }

    func hostWillSleep() async { await connection.hostWillSleep() }
    func hostDidWake() async { await connection.hostDidWake() }

    func removed() async {
        await connection.deviceRemoved()
        await publish(.link(endpoint, .unavailable))
        observer?.cancel()
    }

    func close() async {
        await connection.disconnect()
        observer?.cancel()
    }

    /// The index of `feature`, looked up through Root so the read-only guard can verify it.
    func index(of feature: FeatureID) async -> FeatureIndex? {
        try? await RootFeature.location(of: feature, via: connection, device: deviceIndex, timeout: nil)?.index
    }

    /// The host (Easy-Switch channel) a multi-host keyboard is on; 0 if it cannot tell.
    func currentHost() async -> UInt8 {
        guard let change = await index(of: .changeHost),
            let host = try? await KeyboardFeatures.currentHost(via: connection, index: change, deviceIndex: deviceIndex)
        else { return 0 }
        return host
    }

    // MARK: - Reading after connect

    private func handle(_ state: ConnectionState) async {
        guard state == .connected else {
            await publish(.link(endpoint, DeviceSnapshotMapper.link(for: state)))
            return
        }
        do {
            let inventory = try await DeviceInventoryReader.read(via: connection, deviceIndex: deviceIndex)
            batteryFeature = inventory.battery?.source
            var (observation, draft) = DeviceSnapshotMapper.describe(
                inventory,
                endpoint: endpoint,
                fallbackName: fallbackName,
                product: product
            )
            draft.resolution = await readResolution(inventory)
            resolutionRange = draft.resolution?.range
            draft.smartShift = await readSmartShift(inventory)
            if draft.category == .keyboard { draft.keyboard = await readKeyboard(inventory) }
            await publish(.identified(observation, draft))
        } catch {
            await publish(.link(endpoint, .reconnecting))
        }
    }

    private func locate(_ feature: FeatureID, in inventory: HIDPPDeviceInventory) async -> FeatureIndex? {
        inventory.supports(feature) ? await index(of: feature) : nil
    }

    /// Reads the pointer resolution (read-only); `nil` if absent or unreadable.
    private func readResolution(_ inventory: HIDPPDeviceInventory) async -> ResolutionState? {
        guard
            let index = await locate(.adjustableDPI, in: inventory),
            let current = try? await AdjustableDPIFeature.current(
                via: connection,
                index: index,
                deviceIndex: deviceIndex
            ),
            let range = try? await AdjustableDPIFeature.supportedRange(
                via: connection,
                index: index,
                deviceIndex: deviceIndex
            )
        else { return nil }
        return ResolutionState(current: current, range: range)
    }

    /// Reads the SmartShift mode (read-only); `nil` if absent or unreadable.
    private func readSmartShift(_ inventory: HIDPPDeviceInventory) async -> SmartShiftMode? {
        let feature: FeatureID = inventory.supports(.smartShiftEnhanced) ? .smartShiftEnhanced : .smartShift
        guard let index = await locate(feature, in: inventory) else { return nil }
        return try? await SmartShiftFeature.mode(
            feature: feature,
            via: connection,
            index: index,
            deviceIndex: deviceIndex
        )
    }

    /// Reads the keyboard state (read-only).
    private func readKeyboard(_ inventory: HIDPPDeviceInventory) async -> KeyboardState {
        var state = KeyboardState(functionKeys: nil, backlight: nil, disableableKeys: [], disabledKeys: [])
        if let fn = await locate(.fnInversionMultiHost, in: inventory) {
            let host = await currentHost()
            state.functionKeys = try? await KeyboardFeatures.functionKeys(
                host: host,
                via: connection,
                index: fn,
                deviceIndex: deviceIndex
            )
        }
        if let backlight = await locate(.backlight2, in: inventory) {
            state.backlight = try? await KeyboardFeatures.backlight(
                via: connection,
                index: backlight,
                deviceIndex: deviceIndex
            )
        }
        if let keys = await locate(.disableKeys, in: inventory),
            let read = try? await KeyboardFeatures.disableKeys(via: connection, index: keys, deviceIndex: deviceIndex)
        {
            state.disableableKeys = read.available
            state.disabledKeys = read.disabled
        }
        return state
    }
}
