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
            smartShift: smartShift
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

    nonisolated let endpoint: TransportEndpoint
    private let fallbackName: String
    private let product: ProductID
    private let connection: HIDPPConnection<SessionClock>
    private let publish: Publish
    private var observer: Task<Void, Never>?
    private var batteryFeature: FeatureID?
    private var resolutionRange: ResolutionRange?

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

    /// Writes the resolution (snapped to the supported range) and reads it back.
    func setResolution(_ dpi: Int) async -> (DeviceSettingResult, Int?) {
        guard await connection.state == .connected else { return (.unavailable, nil) }
        guard let range = resolutionRange,
            let index = try? await RootFeature.location(
                of: .adjustableDPI,
                via: connection,
                device: connection.deviceIndex,
                timeout: nil
            )?.index
        else { return (.unsupported, nil) }
        let target = range.nearestSupported(to: dpi)
        do {
            _ = try await AdjustableDPIFeature.set(
                target,
                via: connection,
                index: index,
                deviceIndex: connection.deviceIndex
            )
            let confirmed = try await AdjustableDPIFeature.current(
                via: connection,
                index: index,
                deviceIndex: connection.deviceIndex
            )
            return (confirmed == target ? .applied : .failed, confirmed)
        } catch {
            return (.failed, nil)
        }
    }

    /// Writes the SmartShift mode and reads it back.
    func setSmartShift(_ mode: SmartShiftMode) async -> (DeviceSettingResult, SmartShiftMode?) {
        guard await connection.state == .connected else { return (.unavailable, nil) }
        for feature in [FeatureID.smartShiftEnhanced, .smartShift] {
            guard
                let index = try? await RootFeature.location(
                    of: feature,
                    via: connection,
                    device: connection.deviceIndex,
                    timeout: nil
                )?
                .index
            else { continue }
            do {
                try await SmartShiftFeature.set(
                    mode,
                    feature: feature,
                    via: connection,
                    index: index,
                    deviceIndex: connection.deviceIndex
                )
                let confirmed = try await SmartShiftFeature.mode(
                    feature: feature,
                    via: connection,
                    index: index,
                    deviceIndex: connection.deviceIndex
                )
                return (confirmed == mode ? .applied : .failed, confirmed)
            } catch {
                return (.failed, nil)
            }
        }
        return (.unsupported, nil)
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
    private func locate(_ feature: FeatureID, in inventory: HIDPPDeviceInventory) async -> FeatureIndex? {
        guard inventory.supports(feature) else { return nil }
        return try? await RootFeature.location(
            of: feature,
            via: connection,
            device: connection.deviceIndex,
            timeout: nil
        )?
        .index
    }

    /// Reads the pointer resolution (read-only); `nil` if absent or unreadable.
    private func readResolution(_ inventory: HIDPPDeviceInventory) async -> ResolutionState? {
        guard
            let index = await locate(.adjustableDPI, in: inventory),
            let current = try? await AdjustableDPIFeature.current(
                via: connection,
                index: index,
                deviceIndex: connection.deviceIndex
            ),
            let range = try? await AdjustableDPIFeature.supportedRange(
                via: connection,
                index: index,
                deviceIndex: connection.deviceIndex
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
            deviceIndex: connection.deviceIndex
        )
    }

    private func handle(_ state: ConnectionState) async {
        guard state == .connected else {
            await publish(.link(endpoint, DeviceSnapshotMapper.link(for: state)))
            return
        }
        do {
            let inventory = try await DeviceInventoryReader.read(via: connection, deviceIndex: connection.deviceIndex)
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
            await publish(.identified(observation, draft))
        } catch {
            await publish(.link(endpoint, .reconnecting))
        }
    }
}
