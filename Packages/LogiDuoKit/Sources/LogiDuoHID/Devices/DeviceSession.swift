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
            features: features
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
actor DeviceSession<SessionClock: Clock> where SessionClock.Duration == Duration {
    typealias Publish = @Sendable (DeviceSessionUpdate) async -> Void

    private let endpoint: TransportEndpoint
    private let fallbackName: String
    private let product: ProductID
    private let connection: HIDPPConnection<SessionClock>
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
        guard await connection.state == .connected, let batteryFeature else { return }
        guard
            let location = try? await RootFeature.location(
                of: batteryFeature,
                via: connection,
                device: connection.deviceIndex,
                timeout: nil
            ),
            let reading = try? await BatteryFeature.reading(
                feature: batteryFeature,
                via: connection,
                index: location.index,
                deviceIndex: connection.deviceIndex
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

    private func handle(_ state: ConnectionState) async {
        guard state == .connected else {
            await publish(.link(endpoint, DeviceSnapshotMapper.link(for: state)))
            return
        }
        do {
            let inventory = try await DeviceInventoryReader.read(via: connection, deviceIndex: connection.deviceIndex)
            batteryFeature = inventory.battery?.source
            let (observation, draft) = DeviceSnapshotMapper.describe(
                inventory,
                endpoint: endpoint,
                fallbackName: fallbackName,
                product: product
            )
            await publish(.identified(observation, draft))
        } catch {
            await publish(.link(endpoint, .reconnecting))
        }
    }
}
