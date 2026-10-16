/// Why a transport failed or closed.
public enum HIDPPTransportError: Error, Hashable, Sendable {
    /// The device disappeared.
    case disconnected
    /// The transport is not open.
    case notOpen
    /// macOS denied access (for example missing Input Monitoring permission).
    case accessDenied
    /// The HID stack reported an I/O failure with the given `IOReturn` code.
    case ioFailure(code: Int32)

    /// Whether reopening the transport later may succeed without user action.
    public var isRecoverable: Bool {
        switch self {
        case .disconnected, .notOpen, .ioFailure: true
        case .accessDenied: false
        }
    }
}

/// Something that happened on a transport.
public enum HIDPPTransportEvent: Hashable, Sendable {
    /// An input report, as delivered by the HID stack.
    case input([UInt8])
    /// The transport closed; `nil` for an orderly close.
    case closed(HIDPPTransportError?)
}

/// A bidirectional HID++ link to one HID interface.
///
/// One transport may carry several logical devices (a receiver's slots).
/// Implementations deliver ``events`` to a single consumer in arrival order
/// and finish the stream after ``HIDPPTransportEvent/closed(_:)``.
public protocol HIDPPTransport: Sendable {
    /// How this transport frames reports.
    var framing: HIDPPFraming { get }
    /// Input reports and closure, in order. Consumed by exactly one ``HIDPPChannel``.
    var events: AsyncStream<HIDPPTransportEvent> { get }
    /// Sends one output report.
    func send(_ report: [UInt8]) async throws(HIDPPTransportError)
    /// Closes the transport. Idempotent.
    func close() async
}
