import Foundation
public import IOKit.hid
public import LogiDuoHIDPP

/// A HID++ transport over one IOKit HID device.
///
/// **Scheduling.** The device is scheduled on a private serial dispatch queue
/// (`IOHIDDeviceSetDispatchQueue`); input and removal callbacks run there and
/// only copy bytes into an `AsyncStream`. Output reports are written with the
/// blocking `IOHIDDeviceSetReport` on a separate serial queue, so a slow
/// Bluetooth write never blocks input delivery or a Swift executor.
///
/// **Ownership.** All callbacks share one ``CallbackContext`` that is retained
/// once when registered and released exactly once in the cancel handler,
/// which IOKit runs after the last callback. The input buffer lives as long
/// as the context. The device is closed in the cancel handler as well. The
/// cancel handler never captures the transport, so a transport that is
/// released without ``close()`` is still cancelled from `deinit`.
///
/// The device is opened non-exclusively: other software keeps receiving its reports.
public final class IOKitHIDTransport: HIDPPTransport, @unchecked Sendable {  // Invariant: `state` guarded by `lock`.
    private enum State {
        case open
        case cancelling
        case cancelled
    }

    /// Shared with the C callbacks and the cancel handler.
    private final class CallbackContext: @unchecked Sendable {  // Invariant: buffer touched only on the device queue.
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int
        let sink: AsyncStream<HIDPPTransportEvent>.Continuation

        init(capacity: Int, sink: AsyncStream<HIDPPTransportEvent>.Continuation) {
            self.capacity = capacity
            self.buffer = .allocate(capacity: capacity)
            self.buffer.initialize(repeating: 0, count: capacity)
            self.sink = sink
        }

        deinit {
            buffer.deallocate()
        }
    }

    /// Carries the device reference to the write queue.
    private struct WritableDevice: @unchecked Sendable {  // Invariant: used only for SetReport on `writeQueue`.
        let device: IOHIDDevice
    }

    /// Resumed once the cancel handler has run.
    private final class Completion: @unchecked Sendable {  // Invariant: all state guarded by `lock`.
        private let lock = NSLock()
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if finished { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func finish() {
            let pending = lock.withLock {
                finished = true
                defer { waiters = [] }
                return waiters
            }
            for waiter in pending { waiter.resume() }
        }
    }

    /// How this transport frames reports.
    public let framing: HIDPPFraming
    /// Input reports and closure.
    public let events: AsyncStream<HIDPPTransportEvent>

    private let device: IOHIDDevice
    private let writeQueue: DispatchQueue
    private let completion = Completion()
    private let lock = NSLock()
    private var state = State.open

    /// Opens `device` non-exclusively and starts delivering input reports.
    ///
    /// - Parameters:
    ///   - device: The HID device (one IOKit service).
    ///   - framing: How the device frames HID++ reports.
    ///   - maximumInputReportSize: Size of the input buffer; must cover the largest
    ///     HID++ report the device sends (64 bytes is always sufficient).
    /// - Throws: ``HIDPPTransportError`` if the device cannot be opened.
    public init(
        device: IOHIDDevice,
        framing: HIDPPFraming,
        maximumInputReportSize: Int = HIDPPReportType.veryLong.length
    ) throws(HIDPPTransportError) {
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { throw HIDPPTransportError(ioReturn: openResult) }

        let (events, sink) = AsyncStream.makeStream(
            of: HIDPPTransportEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        self.events = events
        self.framing = framing
        self.device = device
        let queue = DispatchQueue(label: "io.github.bafsheh.LogiDuo.hid.input")
        self.writeQueue = DispatchQueue(label: "io.github.bafsheh.LogiDuo.hid.output")

        let context = CallbackContext(capacity: max(maximumInputReportSize, 1), sink: sink)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        let completion = self.completion

        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceRegisterInputReportCallback(device, context.buffer, context.capacity, Self.inputReport, opaque)
        IOHIDDeviceRegisterRemovalCallback(device, Self.removal, opaque)
        IOHIDDeviceSetCancelHandler(device) {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            let context = Unmanaged<CallbackContext>.fromOpaque(opaque).takeRetainedValue()
            context.sink.yield(.closed(nil))
            context.sink.finish()
            completion.finish()
        }
        IOHIDDeviceActivate(device)
    }

    deinit {
        if lock.withLock({ state == .open }) {
            IOHIDDeviceCancel(device)
        }
    }

    /// Writes one output report. The first byte must be the report ID.
    public func send(_ report: [UInt8]) async throws(HIDPPTransportError) {
        guard let reportID = report.first else { throw .ioFailure(code: kIOReturnBadArgument) }
        guard lock.withLock({ state == .open }) else { throw .notOpen }
        let target = WritableDevice(device: device)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<IOReturn, Never>) in
            writeQueue.async {
                let status = report.withUnsafeBufferPointer { buffer -> IOReturn in
                    guard let bytes = buffer.baseAddress else { return kIOReturnBadArgument }
                    return IOHIDDeviceSetReport(
                        target.device,
                        kIOHIDReportTypeOutput,
                        CFIndex(reportID),
                        bytes,
                        buffer.count
                    )
                }
                continuation.resume(returning: status)
            }
        }
        guard result == kIOReturnSuccess else { throw HIDPPTransportError(ioReturn: result) }
    }

    /// Cancels the device and waits until IOKit has released every callback resource.
    public func close() async {
        let shouldCancel = lock.withLock {
            guard state == .open else { return false }
            state = .cancelling
            return true
        }
        if shouldCancel {
            IOHIDDeviceCancel(device)
        }
        await completion.wait()
        lock.withLock { state = .cancelled }
    }

    // MARK: - C callbacks (run on the device queue; copy and return)

    private static let inputReport: IOHIDReportCallback = { context, result, _, _, _, report, length in
        guard let context, result == kIOReturnSuccess, length > 0 else { return }
        let box = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        let count = min(length, box.capacity)
        box.sink.yield(.input(Array(UnsafeBufferPointer(start: report, count: count))))
    }

    private static let removal: IOHIDCallback = { context, _, _ in
        guard let context else { return }
        let box = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        box.sink.yield(.closed(.disconnected))
    }
}
