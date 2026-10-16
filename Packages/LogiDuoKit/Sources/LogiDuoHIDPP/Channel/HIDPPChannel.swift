/// Why a request did not produce a reply.
public enum HIDPPRequestError: Error, Hashable, Sendable {
    /// No reply arrived in time.
    case timeout
    /// The calling task was cancelled.
    case cancelled
    /// The device answered with a HID++ 2.0 error.
    case deviceError(HIDPP20ErrorCode)
    /// A receiver (or HID++ 1.0 device) answered with an error, for example an empty slot.
    case receiverError(HIDPP10ErrorCode)
    /// The transport failed.
    case transport(HIDPPTransportError)
    /// The channel was closed before or while the request ran.
    case channelClosed
    /// The device connection is not established (see `HIDPPConnection`).
    case notConnected
    /// The request could not be framed for this transport.
    case framing(HIDPPFrameError)

    /// Whether repeating a read request may succeed.
    public var isTransient: Bool {
        switch self {
        case .timeout: true
        case .deviceError(let code): code.isTransient
        case .receiverError(let code): code.isTransient
        case .transport(let error): error.isRecoverable
        case .cancelled, .channelClosed, .notConnected, .framing: false
        }
    }
}

/// Unsolicited traffic from the transport.
public enum HIDPPNotification: Hashable, Sendable {
    /// A HID++ 2.0 message sent by the device on its own (software ID 0).
    case message(HIDPPMessage)
    /// HID++ 1.0 traffic such as receiver notifications.
    case legacy(HIDPPReport)
}

/// Counters for traffic that did not reach a caller.
public struct HIDPPChannelStatistics: Hashable, Sendable {
    /// Replies or errors with a request software ID that matched no outstanding request
    /// (late replies after a timeout or cancellation, duplicates, other software).
    public var unmatchedReplies = 0
    /// HID++ buffers (report ID 0x10, 0x11 or 0x12) that could not be decoded.
    public var malformedReports = 0
    /// Other input reports on the same interface (for example ordinary mouse or keyboard
    /// reports, which share the HID++ interface over Bluetooth); ignored.
    public var otherReports = 0
}

/// Correlates HID++ requests with replies on one transport.
///
/// **Correlation invariant.** At most one request is outstanding per device
/// index. A request completes only with a report from the same device index
/// that echoes its feature index, function and software identifier — a reply,
/// a HID++ 2.0 error report, or a HID++ 1.0 error report whose sub-ID and
/// address equal the request's bytes 2 and 3. Software identifiers rotate
/// through 1...15 per device index, so a late reply to an earlier request
/// (one that timed out or was cancelled) cannot complete a later one unless
/// it arrives fifteen requests later. Reports with software identifier 0 are
/// notifications; other unmatched reports are counted and dropped.
///
/// Requests to different device indexes (receiver slots) run concurrently;
/// requests to one device index run one at a time in arrival order.
///
/// **Lifecycle.** Call ``start()`` once; it consumes the transport's events
/// until the transport closes or ``close()`` is called. Closing fails every
/// outstanding and queued request with ``HIDPPRequestError/channelClosed`` or
/// the transport error, and finishes ``notifications``.
public actor HIDPPChannel<ChannelClock: Clock> where ChannelClock.Duration == Duration {
    private struct Key: Hashable {
        let deviceIndex: DeviceIndex
        let featureIndex: FeatureIndex
        let function: FunctionID
        let softwareID: SoftwareID
    }

    private struct Pending {
        let id: UInt64
        let key: Key
        var result: Result<HIDPPMessage, HIDPPRequestError>?
        var continuation: CheckedContinuation<Result<HIDPPMessage, HIDPPRequestError>, Never>?
        var timeout: Task<Void, Never>?
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Unsolicited traffic. Finishes when the channel closes.
    nonisolated public let notifications: AsyncStream<HIDPPNotification>

    private let transport: any HIDPPTransport
    private let clock: ChannelClock
    private let notificationSink: AsyncStream<HIDPPNotification>.Continuation
    private var pending: [DeviceIndex: Pending] = [:]
    private var busy: Set<DeviceIndex> = []
    private var waiters: [DeviceIndex: [Waiter]] = [:]
    private var lastSoftwareID: [DeviceIndex: UInt8] = [:]
    private var nextRequestID: UInt64 = 0
    private var reader: Task<Void, Never>?
    private var closure: HIDPPRequestError?

    /// Traffic that did not reach a caller.
    public private(set) var statistics = HIDPPChannelStatistics()

    /// Creates a channel over `transport`. Nothing is read until ``start()``.
    public init(transport: any HIDPPTransport, clock: ChannelClock) {
        self.transport = transport
        self.clock = clock
        (notifications, notificationSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// Starts consuming transport events. Calling it again has no effect.
    public func start() {
        guard reader == nil, closure == nil else { return }
        let events = transport.events
        reader = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.finish(.transport(.disconnected))
        }
    }

    /// Whether the channel has been closed.
    public var isClosed: Bool { closure != nil }

    /// Why the channel closed, once it has.
    public var closureReason: HIDPPRequestError? { closure }

    /// The number of requests to `index` that are waiting behind the outstanding one.
    public func queueDepth(for index: DeviceIndex) -> Int { waiters[index]?.count ?? 0 }

    /// Whether a request to `index` has been sent and is awaiting its reply.
    public func isAwaitingReply(from index: DeviceIndex) -> Bool { pending[index] != nil }

    /// Sends `request` and waits for its reply.
    ///
    /// - Parameter timeout: How long to wait for the reply after the request is sent.
    ///   Time spent queued behind another request to the same device index is not counted.
    /// - Returns: The matching reply.
    /// - Throws: ``HIDPPRequestError``. Cancellation of the calling task ends the
    ///   wait with ``HIDPPRequestError/cancelled``; a reply arriving afterwards is dropped.
    public func send(_ request: HIDPPRequest, timeout: Duration) async throws(HIDPPRequestError) -> HIDPPMessage {
        let id = makeRequestID()
        try await acquire(request.deviceIndex, id: id)
        defer { release(request.deviceIndex) }
        if let closure { throw closure }

        let softwareID = rotateSoftwareID(for: request.deviceIndex)
        let key = Key(
            deviceIndex: request.deviceIndex,
            featureIndex: request.featureIndex,
            function: request.function,
            softwareID: softwareID
        )
        let bytes: [UInt8]
        do {
            bytes = try transport.framing.encode(request.report(softwareID: softwareID))
        } catch {
            throw .framing(error)
        }

        // Register and fix the deadline before sending: the reply may arrive while
        // `send` is suspended, and time must be measured from before the send.
        pending[request.deviceIndex] = Pending(id: id, key: key)
        scheduleTimeout(for: request.deviceIndex, id: id, deadline: clock.now.advanced(by: timeout))
        do {
            try await transport.send(bytes)
        } catch {
            complete(request.deviceIndex, id: id, with: .failure(.transport(error)))
        }
        return try await awaitResult(request.deviceIndex, id: id).get()
    }

    /// Closes the channel and the transport, failing all outstanding work.
    public func close() async {
        finish(.channelClosed)
        await transport.close()
    }

    // MARK: - Queueing

    private func makeRequestID() -> UInt64 {
        nextRequestID += 1
        return nextRequestID
    }

    private func acquire(_ index: DeviceIndex, id: UInt64) async throws(HIDPPRequestError) {
        if let closure { throw closure }
        guard busy.contains(index) else {
            busy.insert(index)
            return
        }
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[index, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandonWait(index, id: id) }
        }
        guard granted else {
            throw closure ?? .cancelled
        }
    }

    private func release(_ index: DeviceIndex) {
        if var queue = waiters[index], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[index] = queue.isEmpty ? nil : queue
            next.continuation.resume(returning: true)
        } else {
            busy.remove(index)
        }
    }

    private func abandonWait(_ index: DeviceIndex, id: UInt64) {
        guard let position = waiters[index]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters[index]?.remove(at: position)
        if waiters[index]?.isEmpty == true { waiters[index] = nil }
        waiter?.continuation.resume(returning: false)
    }

    private func rotateSoftwareID(for index: DeviceIndex) -> SoftwareID {
        let range = SoftwareID.requestRange
        let previous = lastSoftwareID[index] ?? range.upperBound
        let next = previous >= range.upperBound ? range.lowerBound : previous + 1
        lastSoftwareID[index] = next
        return SoftwareID(rawValue: next) ?? .notification
    }

    // MARK: - Waiting

    private func scheduleTimeout(for index: DeviceIndex, id: UInt64, deadline: ChannelClock.Instant) {
        guard pending[index]?.id == id, pending[index]?.result == nil else { return }
        let clock = self.clock
        pending[index]?.timeout = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            await self?.complete(index, id: id, with: .failure(.timeout))
        }
    }

    private func awaitResult(_ index: DeviceIndex, id: UInt64) async -> Result<HIDPPMessage, HIDPPRequestError> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let entry = pending[index], entry.id == id else {
                    continuation.resume(returning: .failure(closure ?? .cancelled))
                    return
                }
                if let result = entry.result {
                    pending[index] = nil
                    continuation.resume(returning: result)
                } else {
                    pending[index]?.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.complete(index, id: id, with: .failure(.cancelled)) }
        }
    }

    /// Completes the request `id` if it is still the outstanding one for `index`.
    private func complete(_ index: DeviceIndex, id: UInt64, with result: Result<HIDPPMessage, HIDPPRequestError>) {
        guard var entry = pending[index], entry.id == id, entry.result == nil else { return }
        entry.timeout?.cancel()
        if let continuation = entry.continuation {
            pending[index] = nil
            continuation.resume(returning: result)
        } else {
            entry.result = result
            entry.timeout = nil
            pending[index] = entry
        }
    }

    // MARK: - Inbound

    private func handle(_ event: HIDPPTransportEvent) {
        switch event {
        case .input(let bytes):
            route(bytes)
        case .closed(let error):
            finish(error.map(HIDPPRequestError.transport) ?? .channelClosed)
        }
    }

    /// The HID++ report in `bytes`, counting anything else.
    private func decode(_ bytes: [UInt8]) -> HIDPPReport? {
        guard let reportID = bytes.first, (0x10...0x12).contains(reportID) else {
            statistics.otherReports += 1
            return nil
        }
        do {
            return try transport.framing.decode(bytes)
        } catch {
            statistics.malformedReports += 1
            return nil
        }
    }

    private func route(_ bytes: [UInt8]) {
        guard let report = decode(bytes) else { return }
        switch HIDPPInbound(report) {
        case .message(let message):
            if message.softwareID.isNotification {
                notificationSink.yield(.message(message))
            } else {
                let key = Key(
                    deviceIndex: message.deviceIndex,
                    featureIndex: message.featureIndex,
                    function: message.function,
                    softwareID: message.softwareID
                )
                resolve(key, with: .success(message))
            }
        case .featureError(let error):
            let key = Key(
                deviceIndex: error.deviceIndex,
                featureIndex: error.featureIndex,
                function: error.function,
                softwareID: error.softwareID
            )
            resolve(key, with: .failure(.deviceError(error.code)))
        case .legacyError(let error):
            let key = Key(
                deviceIndex: error.deviceIndex,
                featureIndex: FeatureIndex(rawValue: error.subID),
                function: FunctionID(nibble: error.address >> 4),
                softwareID: SoftwareID(nibble: error.address)
            )
            resolve(key, with: .failure(.receiverError(error.code)))
        case .legacy(let legacy):
            notificationSink.yield(.legacy(legacy))
        }
    }

    private func resolve(_ key: Key, with result: Result<HIDPPMessage, HIDPPRequestError>) {
        guard let entry = pending[key.deviceIndex], entry.key == key, entry.result == nil else {
            statistics.unmatchedReplies += 1
            return
        }
        complete(key.deviceIndex, id: entry.id, with: result)
    }

    private func finish(_ reason: HIDPPRequestError) {
        guard closure == nil else { return }
        closure = reason
        reader?.cancel()
        reader = nil
        for (index, entry) in pending {
            complete(index, id: entry.id, with: .failure(reason))
        }
        for (_, queue) in waiters {
            for waiter in queue { waiter.continuation.resume(returning: false) }
        }
        waiters = [:]
        notificationSink.finish()
    }
}
