import Foundation
public import LogiDuoDomain

/// A stateful fake mouse for configuration tests: ReprogControlsV4 at feature
/// index 1 and DeviceInformation at index 2.
///
/// Controls: 0x0050 (left, not divertable), 0x0052 (middle), 0x00C3 (gesture,
/// raw XY capable) and 0x00C4 (mode shift); none persistently divertable.
/// Failure injection covers dropped writes, writes that are acknowledged but not
/// applied, writes that fail, a changed or unreadable identity, and an
/// unresponsive device.
public final class FakeReprogDevice: @unchecked Sendable {  // Invariant: state guarded by `lock`.
    /// How the device misbehaves.
    public enum Fault: Sendable {
        /// Behaves correctly.
        case none
        /// Answers nothing (asleep or out of range).
        case unresponsive
        /// Acknowledges setCidReporting but does not change state.
        case ignoresWrites
        /// Applies setCidReporting but never answers it (the reply is lost).
        case dropsWriteReplies
    }

    /// The default unit identifier reported by DeviceInformation.
    public static let defaultUnit: UInt32 = 0x1234_5678
    /// The default model identifier bytes reported by DeviceInformation.
    public static let defaultModel: [UInt8] = [0xB0, 0x34, 0x00, 0x00, 0x00, 0x00]

    /// The physical identity the default unit and model correspond to.
    public static var defaultPhysicalID: PhysicalDeviceID {
        guard let model = ModelID(rawValue: 0xB034_0000_0000) else { preconditionFailure("valid model") }
        return PhysicalDeviceID(model: model, unit: UnitID(rawValue: defaultUnit))
    }

    /// The control table: (CID, task, capability flags).
    static let table: [(UInt16, UInt16, UInt16)] = [
        (0x0050, 0x0038, 0x0001), (0x0052, 0x003A, 0x0031), (0x00C3, 0x00A9, 0x0131), (0x00C4, 0x009D, 0x0031),
    ]

    private let lock = NSLock()
    private var flags: [UInt16: UInt8] = [0x0050: 0, 0x0052: 0, 0x00C3: 0, 0x00C4: 0]
    private var remaps: [UInt16: UInt16] = [:]
    private var fault = Fault.none
    private var failingWrites: Set<UInt16> = []
    private var unit = FakeReprogDevice.defaultUnit
    private var model: [UInt8]? = FakeReprogDevice.defaultModel
    private var writes: [(UInt16, UInt8)] = []
    private var afterWrite: (@Sendable (UInt16) -> Void)?

    /// Creates a device with every control native.
    public init() {}

    /// Sets the fault mode.
    public func setFault(_ fault: Fault) { lock.withLock { self.fault = fault } }

    /// Makes setCidReporting for `controls` answer with a HID++ error (state unchanged).
    public func failWrites(to controls: Set<UInt16>) { lock.withLock { failingWrites = controls } }

    /// Changes the reported identity; a `nil` model makes the identity unavailable.
    public func setIdentity(unit: UInt32, model: [UInt8]?) {
        lock.withLock {
            self.unit = unit
            self.model = model
        }
    }

    /// Makes DeviceInformation fail entirely.
    public func hideIdentity() { setIdentity(unit: unit, model: nil) }

    /// Runs `hook` (outside the lock is not guaranteed; keep it trivial) after each applied write.
    public func onWrite(_ hook: (@Sendable (UInt16) -> Void)?) { lock.withLock { afterWrite = hook } }

    /// Sets a control's reporting flags directly (for example to simulate a foreign divert or a power cycle).
    public func setReportingFlags(_ value: UInt8, of control: UInt16) { lock.withLock { flags[control] = value } }

    /// Remaps a control directly (simulates a foreign remap).
    public func setRemap(_ target: UInt16, of control: UInt16) { lock.withLock { remaps[control] = target } }

    /// The reporting flags of `control`.
    public func reportingFlags(of control: UInt16) -> UInt8 { lock.withLock { flags[control] ?? 0 } }

    /// Every setCidReporting received: (control, flags byte).
    public var writeLog: [(UInt16, UInt8)] { lock.withLock { writes } }

    /// Simulates a power cycle: temporary diverts are cleared, persistent bits kept.
    public func powerCycle() { lock.withLock { for key in flags.keys { flags[key] = (flags[key] ?? 0) & 0x04 } } }

    /// A transport responder.
    public var responder: FakeHIDPPTransport.Responder { { [self] sent in respond(to: sent) } }

    private func respond(to sent: [UInt8]) -> [[UInt8]] {
        lock.lock()
        let (replies, hook, written) = reply(to: sent)
        lock.unlock()
        if let hook, let written { hook(written) }
        return replies
    }

    private func reply(to sent: [UInt8]) -> ([[UInt8]], (@Sendable (UInt16) -> Void)?, UInt16?) {
        guard fault != .unresponsive, sent.count == 20 else { return ([], nil, nil) }
        let function = sent[3] >> 4
        let control = UInt16(sent[4]) << 8 | UInt16(sent[5])
        switch (sent[2], function) {
        case (0x00, 0):
            let index: UInt8 =
                switch (sent[4], sent[5]) {
                case (0x1B, 0x04): 0x01
                case (0x00, 0x03): 0x02
                default: 0x00
                }
            return ([HIDPPTestTraffic.reply(to: sent, parameters: [index, 0, 5])], nil, nil)
        case (0x00, 1):
            return ([HIDPPTestTraffic.reply(to: sent, parameters: [4, 5, sent[6]])], nil, nil)
        case (0x02, 0):
            guard let model else { return ([HIDPPTestTraffic.featureError(for: sent, code: 0x05)], nil, nil) }
            let unitBytes = withUnsafeBytes(of: unit.bigEndian, Array.init)
            return ([HIDPPTestTraffic.reply(to: sent, parameters: [1] + unitBytes + [0x00, 0x05] + model)], nil, nil)
        case (0x01, _):
            return reprogReply(to: sent, function: function, control: control)
        default:
            return ([HIDPPTestTraffic.featureError(for: sent, code: 0x07)], nil, nil)
        }
    }

    private func reprogReply(
        to sent: [UInt8],
        function: UInt8,
        control: UInt16
    ) -> ([[UInt8]], (@Sendable (UInt16) -> Void)?, UInt16?) {
        switch function {
        case 0:
            return ([HIDPPTestTraffic.reply(to: sent, parameters: [UInt8(Self.table.count)])], nil, nil)
        case 1:
            guard Int(sent[4]) < Self.table.count else {
                return ([HIDPPTestTraffic.featureError(for: sent, code: 0x02)], nil, nil)
            }
            let (cid, task, capability) = Self.table[Int(sent[4])]
            let parameters: [UInt8] = [
                UInt8(cid >> 8), UInt8(cid & 0xFF), UInt8(task >> 8), UInt8(task & 0xFF),
                UInt8(capability & 0xFF), sent[4], 0, 0, UInt8(capability >> 8),
            ]
            return ([HIDPPTestTraffic.reply(to: sent, parameters: parameters)], nil, nil)
        case 2:
            let remap = remaps[control] ?? 0
            let parameters = [sent[4], sent[5], flags[control] ?? 0, UInt8(remap >> 8), UInt8(remap & 0xFF), 0]
            return ([HIDPPTestTraffic.reply(to: sent, parameters: parameters)], nil, nil)
        case 3:
            writes.append((control, sent[6]))
            guard control != 0x0050, !failingWrites.contains(control) else {
                return ([HIDPPTestTraffic.featureError(for: sent, code: 0x02)], nil, nil)
            }
            if fault != .ignoresWrites { flags[control] = Self.apply(sent[6], to: flags[control] ?? 0) }
            if fault == .dropsWriteReplies { return ([], afterWrite, control) }
            return ([HIDPPTestTraffic.reply(to: sent, parameters: [sent[4], sent[5], sent[6]])], afterWrite, control)
        default:
            return ([HIDPPTestTraffic.featureError(for: sent, code: 0x07)], nil, nil)
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
