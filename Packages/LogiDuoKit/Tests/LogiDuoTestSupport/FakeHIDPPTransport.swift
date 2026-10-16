import Foundation
public import LogiDuoHIDPP

/// A scriptable in-memory HID++ transport.
///
/// Every sent report is recorded and published on ``sentReports``. An
/// optional responder produces replies synchronously for each sent report,
/// and tests can inject arbitrary input, failures and disconnects.
public final class FakeHIDPPTransport: HIDPPTransport, @unchecked Sendable {  // Invariant: state guarded by `lock`.
    /// Produces input reports in response to a sent report.
    public typealias Responder = @Sendable ([UInt8]) -> [[UInt8]]

    /// The framing reported to the channel.
    public let framing: HIDPPFraming
    /// Events consumed by the channel.
    public let events: AsyncStream<HIDPPTransportEvent>
    /// Sent reports, for tests that await traffic.
    public let sentReports: AsyncStream<[UInt8]>

    private let eventSink: AsyncStream<HIDPPTransportEvent>.Continuation
    private let sentSink: AsyncStream<[UInt8]>.Continuation
    private let lock = NSLock()
    private var log: [[UInt8]] = []
    private var responder: Responder?
    private var sendFailure: HIDPPTransportError?
    private var closed = false
    private var closeCount = 0

    /// Creates a transport with `framing` and an optional automatic `responder`.
    public init(framing: HIDPPFraming = .bluetoothLowEnergy, responder: Responder? = nil) {
        self.framing = framing
        self.responder = responder
        (events, eventSink) = AsyncStream.makeStream()
        (sentReports, sentSink) = AsyncStream.makeStream()
    }

    /// Every report sent so far.
    public var sent: [[UInt8]] { lock.withLock { log } }

    /// How many times ``close()`` was called.
    public var closeCalls: Int { lock.withLock { closeCount } }

    /// Replaces the automatic responder.
    public func setResponder(_ responder: Responder?) {
        lock.withLock { self.responder = responder }
    }

    /// Makes every following send fail with `error` (or succeed again with `nil`).
    public func failSends(with error: HIDPPTransportError?) {
        lock.withLock { sendFailure = error }
    }

    /// Records the report, then delivers any scripted replies.
    public func send(_ report: [UInt8]) throws(HIDPPTransportError) {
        let outcome: (HIDPPTransportError?, Responder?) = lock.withLock {
            if closed { return (.notOpen, nil) }
            if let sendFailure { return (sendFailure, nil) }
            log.append(report)
            return (nil, responder)
        }
        if let error = outcome.0 { throw error }
        sentSink.yield(report)
        for reply in outcome.1?(report) ?? [] {
            eventSink.yield(.input(reply))
        }
    }

    /// Injects an input report.
    public func deliver(_ bytes: [UInt8]) {
        eventSink.yield(.input(bytes))
    }

    /// Simulates the device disappearing.
    public func disconnect(_ error: HIDPPTransportError = .disconnected) {
        let wasOpen = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        eventSink.yield(.closed(error))
        eventSink.finish()
    }

    /// Orderly close.
    public func close() {
        let wasOpen = lock.withLock {
            closeCount += 1
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        eventSink.yield(.closed(nil))
        eventSink.finish()
        sentSink.finish()
    }
}
