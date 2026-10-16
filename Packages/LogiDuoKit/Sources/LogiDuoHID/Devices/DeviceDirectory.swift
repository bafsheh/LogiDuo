public import LogiDuoDomain
public import LogiDuoHIDPP
import os

/// Where HID interfaces come from and how they are opened: IOKit, or fakes in tests.
public protocol HIDInterfaceSource: Sendable {
    /// Interface arrivals and removals.
    var events: AsyncStream<HIDDiscoveryEvent> { get }
    /// Opens a HID++ transport to a present interface.
    func transport(registryID: UInt64, framing: HIDPPFraming) throws(HIDPPTransportError) -> any HIDPPTransport
    /// Stops delivering events.
    func stop()
}

extension HIDDeviceMonitor: HIDInterfaceSource {
    public func transport(registryID: UInt64, framing: HIDPPFraming) throws(HIDPPTransportError) -> any HIDPPTransport {
        try openTransport(registryID: registryID, framing: framing)
    }
}

/// Discovers Logitech devices, keeps a connection to each, and publishes snapshots.
///
/// * Directly attached devices get one ``HIDPPConnection``; receivers are probed slot
///   by slot (read-only ping) and each answering slot gets its own connection.
/// * Connections reconnect on their own; Mac sleep and wake are forwarded.
/// * Every transport goes through ``ReadOnlyTransportGuard`` unless writes are
///   authorized, so discovery can never change a device.
/// * Identities come from ``DeviceIdentityRegistry`` (firmware identity when
///   available), so a device keeps its identity across reconnects and transports.
public actor DeviceDirectory<SessionClock: Clock>: DeviceServicing, DeviceSettingsServicing
where SessionClock.Duration == Duration {
    /// The saved settings of a device, replayed when it connects (only while writes are enabled).
    public typealias Preferences = @Sendable (DeviceID) async -> DeviceSettings
    private struct Attachment {
        let descriptor: HIDInterfaceDescriptor
        var sessions: [DeviceSession<SessionClock>]
    }

    private let source: any HIDInterfaceSource
    private let clock: SessionClock
    let authorization: DeviceWriteAuthorization
    private let batteryInterval: Duration
    private let logger = Logger(subsystem: "io.github.bafsheh.LogiDuo", category: "DeviceDirectory")
    private var attachments: [UInt64: Attachment] = [:]
    private var registry = DeviceIdentityRegistry()
    var snapshotsByID: [DeviceID: DeviceSnapshot] = [:]
    private var order: [DeviceID] = []
    private var sessionIDs: [TransportEndpoint: DeviceID] = [:]
    private var subscribers: [Int: AsyncStream<[DeviceSnapshot]>.Continuation] = [:]
    private var nextSubscriber = 0
    private var listener: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var preferences: Preferences = { _ in .unchanged }
    private let ledger: RestorationLedger?
    private var deviceInput: @Sendable (InputEvent) async -> Void = { _ in }
    private var diversion: Set<MouseButton> = []

    /// Creates a directory. Nothing happens until ``start()``.
    public init(
        source: any HIDInterfaceSource,
        clock: SessionClock,
        authorization: DeviceWriteAuthorization,
        ledger: RestorationLedger? = nil,
        batteryInterval: Duration = .seconds(300)
    ) {
        // Diversion needs both: without authorization no ledger is used and nothing is diverted.
        self.ledger = authorization == .enabled ? ledger : nil
        self.source = source
        self.clock = clock
        self.authorization = authorization
        self.batteryInterval = batteryInterval
    }

    /// Sets where device-reported input (diverted buttons, raw motion) goes.
    public func useDeviceInput(_ deliver: @escaping @Sendable (InputEvent) async -> Void) {
        deviceInput = deliver
    }

    /// Diverts exactly `buttons` on every connected device that can (only with write authorization).
    public func setDiversion(_ buttons: Set<MouseButton>) async {
        diversion = buttons
        guard ledger != nil else { return }
        for attachment in attachments.values {
            for session in attachment.sessions { await session.setDiversion(buttons) }
        }
    }

    /// Sets where saved device settings come from.
    public func usePreferences(_ preferences: @escaping Preferences) {
        self.preferences = preferences
    }

    /// Starts listening for interfaces and polling batteries.
    public func start() {
        guard listener == nil else { return }
        let events = source.events
        listener = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        let clock = clock
        let interval = batteryInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                await self?.refresh()
            }
        }
    }

    /// Stops listening and closes every connection.
    public func stop() async {
        listener?.cancel()
        poller?.cancel()
        listener = nil
        poller = nil
        source.stop()
        for attachment in attachments.values {
            for session in attachment.sessions { await session.close() }
        }
        attachments = [:]
    }

    /// The current devices, then every change.
    public func snapshots() -> AsyncStream<[DeviceSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [DeviceSnapshot].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = nextSubscriber
        nextSubscriber += 1
        subscribers[id] = continuation
        continuation.yield(currentSnapshots)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    /// Re-reads every connected device.
    public func refresh() async {
        for attachment in attachments.values {
            for session in attachment.sessions { await session.refresh() }
        }
    }

    /// The Mac is about to sleep.
    public func hostWillSleep() async {
        for attachment in attachments.values {
            for session in attachment.sessions { await session.hostWillSleep() }
        }
    }

    /// The Mac woke.
    public func hostDidWake() async {
        for attachment in attachments.values {
            for session in attachment.sessions { await session.hostDidWake() }
        }
    }

    // MARK: - Discovery

    private func handle(_ event: HIDDiscoveryEvent) async {
        switch event {
        case .added(let descriptor):
            await attach(descriptor)
        case .removed(let registryID):
            guard let attachment = attachments.removeValue(forKey: registryID) else { return }
            for session in attachment.sessions { await session.removed() }
        }
    }

    private func attach(_ descriptor: HIDInterfaceDescriptor) async {
        guard attachments[descriptor.registryID] == nil else { return }
        switch HIDInterfaceClassifier.role(of: descriptor) {
        case .directDevice(let link, let framing):
            let key = EndpointKey(rawValue: descriptor.linkFingerprint ?? "registry-\(descriptor.registryID)")
            guard let key else { return }
            let session = makeSession(descriptor, framing: framing, index: .direct, endpoint: .direct(link, key))
            attachments[descriptor.registryID] = Attachment(descriptor: descriptor, sessions: [session])
            await session.setDiversion(diversion)
            await session.start()
        case .receiver(_, let framing):
            attachments[descriptor.registryID] = Attachment(descriptor: descriptor, sessions: [])
            await probeReceiver(descriptor, framing: framing)
        case .logitechWithoutHIDPP, .unrelated:
            return
        }
    }

    /// Pings slots 1–6 on one temporary channel; each answering slot gets a session.
    private func probeReceiver(_ descriptor: HIDInterfaceDescriptor, framing: HIDPPFraming) async {
        guard
            let receiverID = ReceiverID(rawValue: descriptor.linkFingerprint ?? "receiver-\(descriptor.registryID)"),
            let probeTransport = try? openGuarded(descriptor.registryID, framing: framing)
        else { return }
        let receiver = ReceiverDescriptor(id: receiverID, hardware: descriptor.hardware)
        let channel = HIDPPChannel(transport: probeTransport, clock: clock)
        await channel.start()
        var sessions: [DeviceSession<SessionClock>] = []
        for raw in UInt8(1)...6 {
            guard let slot = ReceiverSlot(rawValue: raw) else { continue }
            let index = DeviceIndex(receiverSlot: slot)
            guard
                (try? await RootFeature.protocolVersion(via: channel, device: index, timeout: .milliseconds(600)))
                    != nil
            else { continue }
            sessions.append(
                makeSession(descriptor, framing: framing, index: index, endpoint: .receiver(receiver, slot))
            )
        }
        await channel.close()
        attachments[descriptor.registryID]?.sessions = sessions
        for session in sessions {
            await session.setDiversion(diversion)
            await session.start()
        }
    }

    private func makeSession(
        _ descriptor: HIDInterfaceDescriptor,
        framing: HIDPPFraming,
        index: DeviceIndex,
        endpoint: TransportEndpoint
    ) -> DeviceSession<SessionClock> {
        let registryID = descriptor.registryID
        let open: HIDPPConnection<SessionClock>.TransportFactory = { [weak self] () async throws(HIDPPTransportError) in
            guard let self else { throw .disconnected }
            return try await self.openGuarded(registryID, framing: framing)
        }
        return DeviceSession(
            endpoint: endpoint,
            fallbackName: descriptor.productName ?? "Logitech device",
            product: descriptor.hardware.product,
            deviceIndex: index,
            clock: clock,
            openTransport: open,
            ledger: ledger,
            deliver: { [weak self] event in await self?.forward(event) },
            publish: { [weak self] update in
                await self?.apply(update)
            }
        )
    }

    private func openGuarded(
        _ registryID: UInt64,
        framing: HIDPPFraming
    ) throws(HIDPPTransportError) -> any HIDPPTransport {
        let raw = try source.transport(registryID: registryID, framing: framing)
        return authorization == .enabled ? raw : ReadOnlyTransportGuard(wrapping: raw)
    }

    private func forward(_ event: InputEvent) async {
        await deviceInput(event)
    }

    // MARK: - Snapshots

    private func apply(_ update: DeviceSessionUpdate) {
        let id: DeviceID
        switch update {
        case .identified(let observation, let draft):
            id = registry.reconcile(observation).identity.id
            snapshotsByID[id] = draft.snapshot(id: id)
            if !order.contains(id) { order.append(id) }
            sessionIDs[observation.endpoint] = id
            if authorization == .enabled { replayPreferences(for: id) }
        case .link(let endpoint, let link):
            guard
                let known = snapshotsByID.values.first(where: { snapshot in
                    registry.identity(for: snapshot.id)?.endpoint == endpoint
                })
            else { return }
            id = known.id
            snapshotsByID[id]?.link = link
        case .battery(let endpoint, let battery):
            guard
                let known = snapshotsByID.values.first(where: { snapshot in
                    registry.identity(for: snapshot.id)?.endpoint == endpoint
                })
            else { return }
            id = known.id
            snapshotsByID[id]?.battery = battery
        }
        logger.debug("device \(id, privacy: .public) updated")
        broadcast()
    }

    private var currentSnapshots: [DeviceSnapshot] { order.compactMap { snapshotsByID[$0] } }

    func session(for device: DeviceID) -> DeviceSession<SessionClock>? {
        guard let endpoint = sessionIDs.first(where: { $0.value == device })?.key else { return nil }
        return attachments.values.lazy.flatMap(\.sessions).first { $0.endpoint == endpoint }
    }

    /// Re-applies saved settings after a device connects (HID-052).
    private func replayPreferences(for device: DeviceID) {
        let preferences = preferences
        Task { [weak self] in
            let settings = await preferences(device)
            if let resolution = settings.resolution { _ = await self?.setResolution(resolution, on: device) }
            if let smartShift = settings.smartShift { _ = await self?.setSmartShift(smartShift, on: device) }
        }
    }

    func broadcast() {
        let current = currentSnapshots
        for subscriber in subscribers.values { subscriber.yield(current) }
    }

    private func unsubscribe(_ id: Int) {
        subscribers[id] = nil
    }
}
