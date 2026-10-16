public import LogiDuoDomain
import os

/// Owns the connection to one logical HID++ device and keeps it alive.
///
/// The connection drives the domain ``ConnectionStateMachine``: it opens a
/// transport through an injected factory, verifies the device with a
/// handshake, and reconnects with backoff after failures, unresponsiveness
/// or wake from sleep. Requests are only accepted while ``state`` is
/// `.connected`.
///
/// **Generations.** Every connection attempt and every teardown starts a new
/// generation. Work started for one generation (an open, a handshake, the
/// channel monitor, a scheduled reconnect) re-checks the generation after
/// each suspension and abandons itself if it is stale, so callbacks from an
/// old transport can never change a newer session.
///
/// **Retries.** Read requests that fail transiently are retried up to the
/// configured limit on the same channel; write requests are never retried.
public actor HIDPPConnection<ChannelClock: Clock> where ChannelClock.Duration == Duration {
    /// Opens a fresh transport for this device.
    public typealias TransportFactory = @Sendable () async throws(HIDPPTransportError) -> any HIDPPTransport
    /// Verifies that a newly opened channel reaches the device. Must only read.
    public typealias Handshake =
        @Sendable (HIDPPChannel<ChannelClock>, DeviceIndex, Duration) async throws(HIDPPRequestError) -> Void

    /// The device index requests are addressed to.
    public let deviceIndex: DeviceIndex
    /// Every state change, in order.
    nonisolated public let states: AsyncStream<ConnectionState>
    /// Device notifications from every generation, in order.
    nonisolated public let notifications: AsyncStream<HIDPPNotification>

    /// The current lifecycle state.
    public private(set) var state: ConnectionState = .discovered
    /// The current generation; increases with every attempt and teardown.
    public private(set) var generation: UInt64 = 0
    /// Events the state machine rejected (should stay zero).
    public private(set) var rejectedEvents = 0
    /// How many transports this connection has opened.
    public private(set) var openedTransports = 0

    private let configuration: HIDPPConnectionConfiguration
    private let machine: ConnectionStateMachine
    private let clock: ChannelClock
    private let openTransport: TransportFactory
    private let handshake: Handshake
    private let stateSink: AsyncStream<ConnectionState>.Continuation
    private let notificationSink: AsyncStream<HIDPPNotification>.Continuation
    private let logger = Logger(subsystem: "io.github.bafsheh.LogiDuo", category: "HIDPPConnection")
    private var channel: HIDPPChannel<ChannelClock>?
    /// The channel of an attempt that is still handshaking; closed by teardown.
    private var handshakingChannel: HIDPPChannel<ChannelClock>?
    private var monitor: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var consecutiveTimeouts = 0

    /// Creates a connection in the `.discovered` state. Nothing is opened until ``connect()``.
    public init(
        deviceIndex: DeviceIndex,
        configuration: HIDPPConnectionConfiguration,
        clock: ChannelClock,
        openTransport: @escaping TransportFactory,
        handshake: @escaping Handshake
    ) {
        self.deviceIndex = deviceIndex
        self.configuration = configuration
        self.machine = ConnectionStateMachine(retryPolicy: configuration.retryPolicy)
        self.clock = clock
        self.openTransport = openTransport
        self.handshake = handshake
        (states, stateSink) = AsyncStream.makeStream()
        (notifications, notificationSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    // MARK: - Commands

    /// Connects, if the current state allows it, and returns after the first attempt.
    public func connect() async {
        guard apply(.connectRequested) else { return }
        await attempt()
    }

    /// Sends `request`, retrying transient failures of reads.
    /// - Throws: ``HIDPPRequestError/notConnected`` unless the state is `.connected`.
    public func perform(
        _ request: HIDPPRequest,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> HIDPPMessage {
        let attempts = request.kind == .read ? 1 + max(0, configuration.readRetryLimit) : 1
        var lastError = HIDPPRequestError.notConnected
        for attemptNumber in 1...attempts {
            guard state.acceptsCommands, let channel else { throw .notConnected }
            let session = generation
            do {
                let reply = try await channel.send(request, timeout: timeout ?? configuration.requestTimeout)
                if session == generation { consecutiveTimeouts = 0 }
                return reply
            } catch {
                lastError = error
                if error == .timeout, session == generation {
                    consecutiveTimeouts += 1
                    if consecutiveTimeouts >= configuration.unresponsiveThreshold {
                        await deviceBecameUnresponsive()
                        throw error
                    }
                }
                guard request.kind == .read, error.isTransient, attemptNumber < attempts else { throw error }
            }
        }
        throw lastError
    }

    /// Closes the connection and stops reconnecting.
    public func disconnect() async {
        guard apply(.disconnectRequested) else { return }
        await tearDown()
        apply(.disconnectCompleted)
    }

    /// The device disappeared from the system; stops all activity.
    public func deviceRemoved() async {
        guard apply(.deviceRemoved) else { return }
        await tearDown()
    }

    /// The device reappeared after removal or a requested disconnect.
    public func deviceRediscovered() {
        apply(.deviceDiscovered)
    }

    /// The Mac is about to sleep: closes the link and suspends reconnection.
    public func hostWillSleep() async {
        guard apply(.hostWillSleep), state == .suspended else { return }
        await tearDown()
    }

    /// The Mac woke: reconnects after the wake delay so device settings are re-applied.
    public func hostDidWake() async {
        guard apply(.hostDidWake), case .recovering = state else { return }
        let closing = invalidateSession()
        scheduleReconnect(after: configuration.backoff.afterWake)
        await close(closing)
    }

    // MARK: - Attempts

    private func attempt() async {
        generation += 1
        let session = generation
        guard let channel = await openChannel(session: session) else { return }
        do {
            try await handshake(channel, deviceIndex, configuration.handshakeTimeout)
        } catch {
            await channel.close()
            guard isCurrentAttempt(session) else { return }
            handshakingChannel = nil
            fail(with: Self.fault(for: error))
            return
        }
        guard isCurrentAttempt(session) else {
            await channel.close()
            return
        }
        activate(channel, session: session)
    }

    /// Opens a transport and starts a channel for attempt `session`, or records the failure.
    private func openChannel(session: UInt64) async -> HIDPPChannel<ChannelClock>? {
        let transport: any HIDPPTransport
        do {
            transport = try await openTransport()
            openedTransports += 1
        } catch {
            if isCurrentAttempt(session) { fail(with: Self.fault(for: error)) }
            return nil
        }
        guard isCurrentAttempt(session) else {
            await transport.close()
            return nil
        }
        let channel = HIDPPChannel(transport: transport, clock: clock)
        handshakingChannel = channel
        await channel.start()
        return channel
    }

    private func activate(_ channel: HIDPPChannel<ChannelClock>, session: UInt64) {
        handshakingChannel = nil
        self.channel = channel
        consecutiveTimeouts = 0
        monitor = Task { [weak self] in
            for await notification in channel.notifications {
                await self?.forward(notification, session: session)
            }
            await self?.channelEnded(session: session)
        }
        apply(.connectSucceeded)
    }

    private func isCurrentAttempt(_ session: UInt64) -> Bool {
        session == generation && { if case .connecting = state { true } else { false } }()
    }

    private func fail(with fault: ConnectionFault) {
        apply(.connectFailed(fault))
        if case .recovering(_, let failures) = state {
            scheduleReconnect(after: configuration.backoff.delay(afterFailures: failures))
        }
    }

    private func scheduleReconnect(after delay: Duration) {
        reconnect?.cancel()
        let session = generation
        let deadline = clock.now.advanced(by: delay)
        let clock = self.clock
        reconnect = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            await self?.reconnectDue(session: session)
        }
    }

    private func reconnectDue(session: UInt64) async {
        guard session == generation, case .recovering = state else { return }
        reconnect = nil
        await connect()
    }

    // MARK: - Channel events

    private func forward(_ notification: HIDPPNotification, session: UInt64) {
        guard session == generation else { return }
        notificationSink.yield(notification)
    }

    private func channelEnded(session: UInt64) async {
        guard session == generation, state == .connected else { return }
        logger.info("HID++ channel ended; recovering")
        await deviceBecameUnresponsive()
    }

    private func deviceBecameUnresponsive() async {
        guard apply(.communicationLost) else { return }
        let closing = invalidateSession()
        scheduleReconnect(after: configuration.backoff.delay(afterFailures: 0))
        await close(closing)
    }

    /// Invalidates the current generation and releases its resources.
    private func tearDown() async {
        await close(invalidateSession())
    }

    /// Synchronously starts a new generation, cancels its tasks and returns its channels.
    ///
    /// Kept free of suspension points so that callers can schedule follow-up
    /// work (such as a reconnect deadline) before anything else observes the change.
    private func invalidateSession() -> [HIDPPChannel<ChannelClock>] {
        generation += 1
        reconnect?.cancel()
        reconnect = nil
        monitor?.cancel()
        monitor = nil
        consecutiveTimeouts = 0
        let closing = [channel, handshakingChannel].compactMap(\.self)
        channel = nil
        handshakingChannel = nil
        return closing
    }

    private func close(_ channels: [HIDPPChannel<ChannelClock>]) async {
        for channel in channels {
            await channel.close()
        }
    }

    // MARK: - State

    @discardableResult
    private func apply(_ event: ConnectionEvent) -> Bool {
        do {
            let next = try machine.transition(from: state, on: event)
            if next != state {
                state = next
                stateSink.yield(next)
            }
            return true
        } catch {
            rejectedEvents += 1
            logger.error("Rejected connection event in state \(String(describing: self.state), privacy: .public)")
            return false
        }
    }

    static func fault(for error: HIDPPTransportError) -> ConnectionFault {
        error == .accessDenied ? .permanent(.accessDenied) : .transient(.ioError)
    }

    static func fault(for error: HIDPPRequestError) -> ConnectionFault {
        switch error {
        case .timeout: .transient(.timeout)
        case .deviceError(let code):
            if code.isTransient { .transient(.busy) } else { .permanent(.unsupportedProtocol) }
        case .receiverError(let code):
            if code.isTransient { .transient(.busy) } else { .transient(.ioError) }
        case .transport(let transport): fault(for: transport)
        case .framing: .permanent(.unsupportedProtocol)
        case .cancelled, .channelClosed, .notConnected: .transient(.ioError)
        }
    }
}
