import Foundation
public import LogiDuoHIDPP

/// Hands out fake transports (or failures) in order, recording every open.
public final class FakeTransportFactory: @unchecked Sendable {  // Invariant: state guarded by `lock`.
    /// One scripted result of opening a transport.
    public enum Outcome: Sendable {
        /// Open succeeds with a new transport using `responder`.
        case open(FakeHIDPPTransport.Responder?)
        /// Open fails.
        case fail(HIDPPTransportError)
    }

    private let lock = NSLock()
    private var script: [Outcome]
    private let fallback: Outcome
    private var opened: [FakeHIDPPTransport] = []
    private var attempts = 0

    /// Creates a factory that follows `script`, then repeats `fallback`.
    public init(_ script: [Outcome] = [], fallback: Outcome) {
        self.script = script
        self.fallback = fallback
    }

    /// Transports opened so far, oldest first.
    public var transports: [FakeHIDPPTransport] { lock.withLock { opened } }

    /// Open attempts so far, including failures.
    public var openAttempts: Int { lock.withLock { attempts } }

    /// Opens the next scripted transport.
    public func open() throws(HIDPPTransportError) -> any HIDPPTransport {
        let outcome = lock.withLock {
            attempts += 1
            return script.isEmpty ? fallback : script.removeFirst()
        }
        switch outcome {
        case .fail(let error):
            throw error
        case .open(let responder):
            let transport = FakeHIDPPTransport(responder: responder)
            lock.withLock { opened.append(transport) }
            return transport
        }
    }

    /// A responder that answers the Root protocol-version ping with version 4.5.
    public static let rootResponder: FakeHIDPPTransport.Responder = { sent in
        guard sent[2] == 0x00, sent[3] >> 4 == 1 else { return [HIDPPTestTraffic.reply(to: sent)] }
        return [HIDPPTestTraffic.reply(to: sent, parameters: [0x04, 0x05, sent[6]])]
    }
}
