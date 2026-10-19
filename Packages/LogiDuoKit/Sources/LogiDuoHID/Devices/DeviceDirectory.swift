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
    struct Attachment {
        let descriptor: HIDInterfaceDescriptor
        var sessions: [DeviceSession<SessionClock>]
    }

    private let source: any HIDInterfaceSource
    let clock: SessionClock
    let authorization: DeviceWriteAuthorization
    private let batteryInterval: Duration
    private let logger = Logger(subsystem: "io.github.bafsheh.LogiDuo", category: "DeviceDirectory")
    var attachments: [UInt64: Attachment] = [:]
    private var registry = DeviceIdentityRegistry()
    var snapshotsByID: [DeviceID: DeviceSnapshot] = [:]
    private var order: [DeviceID] = []
    private var sessionIDs: [TransportEndpoint: DeviceID] = [:]
    private var subscribers: [Int: AsyncStream<[DeviceSnapshot]>.Continuation] = [:]
    private var nextSubscriber = 0
    private var listener: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// False after ``stop()``: attaches and probes still in flight must not start sessions.
    var isRunning = false
    private var preferences: Preferences = { _ in .unchanged }
    private let ledger: RestorationLedger?
    private var deviceInput: @Sendable (InputEvent) async -> Void = { _ in }
    var diversion: Set<MouseButton> = []

    /// Creates a directory. Nothing happens until ``start()``.
    public init(
        source: any HIDInterfaceSource,
        clock: SessionClock,
        authorization: DeviceWriteAuthorization,
        ledger: RestorationLedger? = nil,
        batteryInterval: Duration = .seconds(300)
    ) {
        // Diversion needs both: without authorization no ledger is used and nothing is diverted.
        self.ledger = authorization.allowsDiversion ? ledger : nil
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
            // Always the latest request: an older call that arrives later must not win.
            for session in attachment.sessions { await session.setDiversion(diversion) }
        }
    }

    /// Sets where saved device settings come from.
    public func usePreferences(_ preferences: @escaping Preferences) {
        self.preferences = preferences
    }

    /// Starts listening for interfaces and polling batteries.
    public func start() {
        guard listener == nil else { return }
        isRunning = true
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
        isRunning = false
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

    /// The devices known right now.
    public func knownDevices() -> [DeviceSnapshot] { currentSnapshots }

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

    /// Re-reads every connected device and retries those whose connection gave up.
    public func refresh() async {
        await reprobeReceivers()
        for attachment in attachments.values {
            for session in attachment.sessions {
                await session.retryIfGaveUp()
                await session.refresh()
            }
        }
    }

    /// Input Monitoring was granted: retries every interface macOS refused to open,
    /// so devices appear without relaunching LogiDuo.
    public func accessGranted() async {
        await reprobeReceivers()
        await retryGivenUpSessions()
    }

    private func retryGivenUpSessions() async {
        for attachment in attachments.values {
            for session in attachment.sessions { await session.retryIfGaveUp() }
        }
    }

    /// The Mac is about to sleep.
    public func hostWillSleep() async {
        for attachment in attachments.values {
            for session in attachment.sessions { await session.hostWillSleep() }
        }
    }

    /// The Mac woke. Devices that gave up while it slept or idled get another attempt:
    /// a wake usually means someone is using them again.
    public func hostDidWake() async {
        for attachment in attachments.values {
            for session in attachment.sessions { await session.hostDidWake() }
        }
        await retryGivenUpSessions()
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

    func makeSession(
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

    func openGuarded(
        _ registryID: UInt64,
        framing: HIDPPFraming
    ) throws(HIDPPTransportError) -> any HIDPPTransport {
        let raw: any HIDPPTransport
        do {
            raw = try source.transport(registryID: registryID, framing: framing)
        } catch {
            // Usually missing Input Monitoring: the HID++ interface also carries ordinary input.
            logger.notice("could not open a device interface: \(String(describing: error), privacy: .public)")
            throw error
        }
        return authorization.limiting(raw)
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
