import Foundation

/// A stateful fake mouse with ReprogControlsV4 at feature index 1, for configuration tests.
///
/// Controls: 0x0050 (left, not divertable), 0x00C3 (gesture) and 0x00C4 (mode shift),
/// both divertable but not persistently. Failure injection covers dropped writes,
/// writes that are acknowledged but not applied, and an unresponsive device.
public final class FakeReprogDevice: @unchecked Sendable {  // Invariant: state guarded by `lock`.
    /// How the device misbehaves.
    public enum Fault: Sendable {
        /// Behaves correctly.
        case none
        /// Answers nothing (asleep or out of range).
        case unresponsive
        /// Acknowledges setCidReporting but does not change state.
        case ignoresWrites
    }

    private let lock = NSLock()
    private var flags: [UInt16: UInt8] = [0x0050: 0, 0x00C3: 0, 0x00C4: 0]
    private var fault = Fault.none
    private var writes: [(UInt16, UInt8)] = []

    /// Creates a device with every control native.
    public init() {}

    /// Sets the fault mode.
    public func setFault(_ fault: Fault) { lock.withLock { self.fault = fault } }

    /// Sets a control's reporting flags directly (for example to simulate a foreign divert or a power cycle).
    public func setReportingFlags(_ value: UInt8, of control: UInt16) { lock.withLock { flags[control] = value } }

    /// The reporting flags of `control`.
    public func reportingFlags(of control: UInt16) -> UInt8 { lock.withLock { flags[control] ?? 0 } }

    /// Every setCidReporting received: (control, flags byte).
    public var writeLog: [(UInt16, UInt8)] { lock.withLock { writes } }

    /// Simulates a power cycle: temporary diverts are cleared.
    public func powerCycle() { lock.withLock { for key in flags.keys { flags[key] = 0 } } }

    /// A transport responder.
    public var responder: FakeHIDPPTransport.Responder { { [self] sent in respond(to: sent) } }

    private func respond(to sent: [UInt8]) -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        guard fault != .unresponsive, sent.count == 20 else { return [] }
        let function = sent[3] >> 4
        switch (sent[2], function) {
        case (0x00, 0):
            let index: UInt8 = sent[4] == 0x1B && sent[5] == 0x04 ? 0x01 : 0x00
            return [HIDPPTestTraffic.reply(to: sent, parameters: [index, 0, 5])]
        case (0x00, 1):
            return [HIDPPTestTraffic.reply(to: sent, parameters: [4, 5, sent[6]])]
        case (0x01, 2):
            let control = UInt16(sent[4]) << 8 | UInt16(sent[5])
            return [HIDPPTestTraffic.reply(to: sent, parameters: [sent[4], sent[5], flags[control] ?? 0, 0, 0, 0])]
        case (0x01, 3):
            let control = UInt16(sent[4]) << 8 | UInt16(sent[5])
            writes.append((control, sent[6]))
            guard control != 0x0050 else { return [HIDPPTestTraffic.featureError(for: sent, code: 0x02)] }
            if fault == .none { flags[control] = Self.apply(sent[6], to: flags[control] ?? 0) }
            return [HIDPPTestTraffic.reply(to: sent, parameters: [sent[4], sent[5], sent[6]])]
        default:
            return [HIDPPTestTraffic.featureError(for: sent, code: 0x07)]
        }
    }

    /// Applies a setCidReporting flags byte: each value bit takes effect only with its valid bit.
    static func apply(_ request: UInt8, to current: UInt8) -> UInt8 {
        var state = current
        if request & 0x02 != 0 { state = (state & ~0x01) | (request & 0x01) }
        if request & 0x08 != 0 { state = (state & ~0x04) | (request & 0x04) }
        if request & 0x20 != 0 { state = (state & ~0x10) | (request & 0x10) }
        return state
    }
}
