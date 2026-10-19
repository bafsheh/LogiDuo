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
    var wantedDiversion: Set<MouseButton> = []
    /// Controls diverted on the current connection (lost on reconnect).
    var activeDiversion: Set<UInt16> = []
    /// Controls this run diverted and recorded; restored when no longer wanted, even after a reconnect.
    var divertedThisRun: Set<UInt16> = []
    var diversionContext: DiversionContext?
    var decoder = DivertedControlsDecoder()
    var applyingDiversion = false
    var diversionDirty = false
    var diversionWaiters: [CheckedContinuation<Void, Never>] = []
    private let ledger: RestorationLedger?
    private let deliver: @Sendable (InputEvent) async -> Void
    private var notificationObserver: Task<Void, Never>?
    private let clock: SessionClock
    private var isRemoved = false
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
        ledger: RestorationLedger? = nil,
        deliver: @escaping @Sendable (InputEvent) async -> Void = { _ in },
        publish: @escaping Publish
    ) {
        self.ledger = ledger
        self.deliver = deliver
        self.endpoint = endpoint
        self.fallbackName = fallbackName
        self.product = product
        self.publish = publish
        self.deviceIndex = deviceIndex
        self.clock = clock
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
        let notifications = connection.notifications
        notificationObserver = Task { [weak self] in
            for await notification in notifications {
                await self?.received(notification)
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

    /// Connects again if the connection gave up because macOS refused access or the device
    /// stopped answering (for example a mouse asleep for minutes); anything else is left alone.
    func retryIfGaveUp() async {
        guard !isRemoved else { return }
        switch await connection.state {
        case .failed(.accessDenied), .failed(.retriesExhausted): await connection.connect()
        default: return
        }
    }

    func hostWillSleep() async { await connection.hostWillSleep() }
    func hostDidWake() async { await connection.hostDidWake() }

    func removed() async {
        isRemoved = true
        await releaseHeld()
        await connection.deviceRemoved()
        await publish(.link(endpoint, .unavailable))
        observer?.cancel()
        notificationObserver?.cancel()
    }

    func close() async {
        await restoreDiversion()
        await releaseHeld()
        await connection.disconnect()
        observer?.cancel()
        notificationObserver?.cancel()
    }

    private func received(_ notification: HIDPPNotification) async {
        for event in decode(notification) { await deliver(event) }
    }

    private func releaseHeld() async {
        for event in decoder.releaseAll() { await deliver(event) }
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
            await releaseHeld()
            activeDiversion = []
            await publish(.link(endpoint, DeviceSnapshotMapper.link(for: state)))
            return
        }
        await identify()
    }

    /// Reads the device after connecting, retrying a few times: a single failed read must not
    /// leave it unidentified while the connection itself stays up.
    private func identify() async {
        for attempt in 0..<3 {
            guard !isRemoved, await connection.state == .connected else { return }
            if attempt > 0 { try? await clock.sleep(for: .seconds(1)) }
            guard let inventory = try? await DeviceInventoryReader.read(via: connection, deviceIndex: deviceIndex)
            else {
                continue
            }
            guard !isRemoved else { return }
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
            await prepareDiversion(inventory)
            return
        }
        if !isRemoved { await publish(.link(endpoint, .reconnecting)) }
    }

    /// Learns where to divert (only with a ledger, which the directory passes when writes are authorized).
    private func prepareDiversion(_ inventory: HIDPPDeviceInventory) async {
        activeDiversion = []
        guard let ledger, let physical = inventory.information?.physicalID,
            let reprog = await locate(.reprogControlsV4, in: inventory),
            let information = await index(of: .deviceInformation)
        else { return }
        let target = ConfigurableDevice(
            identity: DeviceID(physical: physical),
            physical: physical,
            deviceIndex: deviceIndex,
            reprogIndex: reprog,
            informationIndex: information
        )
        diversionContext = DiversionContext(target: target, ledger: ledger)
        await applyDiversion()
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
