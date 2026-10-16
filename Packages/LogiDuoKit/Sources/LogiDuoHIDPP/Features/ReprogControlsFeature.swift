/// Static capability flags of a reprogrammable control (getCidInfo).
public struct ControlFlags: OptionSet, Hashable, Sendable {
    /// A mouse button.
    public static let mouseButton = ControlFlags(rawValue: 0x0001)
    /// Can be reprogrammed (remapped to another control).
    public static let reprogrammable = ControlFlags(rawValue: 0x0010)
    /// Can be temporarily diverted to the host.
    public static let divertable = ControlFlags(rawValue: 0x0020)
    /// Can be persistently diverted (stored in the device).
    public static let persistentlyDivertable = ControlFlags(rawValue: 0x0040)
    /// A virtual control (no physical button).
    public static let virtual = ControlFlags(rawValue: 0x0080)
    /// Can report raw XY movement while held.
    public static let rawXY = ControlFlags(rawValue: 0x0100)

    /// The 16-bit flags.
    public let rawValue: UInt16

    /// Creates flags.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

/// Current reporting state of a control (getCidReporting).
///
/// Bit layout (low byte): bit0 diverted, bit2 persistently diverted, bit4 raw XY diverted.
public struct ControlReporting: Hashable, Sendable {
    /// The control.
    public let control: UInt16
    /// The raw reporting flags.
    public let flags: UInt16
    /// The control it is remapped to (the control itself when not remapped).
    public let remappedTo: UInt16

    /// Temporarily diverted to the host.
    public var isDiverted: Bool { flags & 0x0001 != 0 }
    /// Persistently diverted (survives power cycles).
    public var isPersistentlyDiverted: Bool { flags & 0x0004 != 0 }
    /// Raw XY diverted.
    public var isRawXYDiverted: Bool { flags & 0x0010 != 0 }
    /// Whether the control behaves natively: no reporting bit of any kind set, not remapped.
    ///
    /// Strict on purpose: unknown or reserved bits mean "not native", so LogiDuo
    /// never takes over a control in a state it does not fully understand.
    public var isNative: Bool { flags == 0 && remappedTo == control }
}

/// A reprogrammable control and its current state.
public struct ReprogrammableControl: Hashable, Sendable {
    /// Control identifier (CID).
    public let control: UInt16
    /// Task identifier.
    public let task: UInt16
    /// Capability flags.
    public let flags: ControlFlags
    /// Current reporting state.
    public let reporting: ControlReporting?
}

/// Read-only access to ReprogControlsV4 (0x1B04).
///
/// ```
/// fn0 getCount                → [count]
/// fn1 getCidInfo(index)       → [cid(2), task(2), flags lo, position, group, group mask, flags hi]
/// fn2 getCidReporting(cid)    → [cid(2), flags lo, remap(2), flags hi]
/// fn3 setCidReporting         — a WRITE; not exposed here.
/// ```
public enum ReprogControlsFeature {
    /// The control table with each control's current reporting state.
    public static func controls(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> [ReprogrammableControl] {
        let count = try await device.perform(FeatureRequest.read(deviceIndex, index, 0), timeout: timeout).parameters[0]
        var controls: [ReprogrammableControl] = []
        for position in 0..<min(count, 32) {
            let info = try await device.perform(
                FeatureRequest.read(deviceIndex, index, 1, [position]),
                timeout: timeout
            )
            .parameters
            let cid = FeatureRequest.bigEndian(info[0...1], as: UInt16.self)
            controls.append(
                ReprogrammableControl(
                    control: cid,
                    task: FeatureRequest.bigEndian(info[2...3], as: UInt16.self),
                    flags: ControlFlags(rawValue: UInt16(info[4]) | UInt16(info[8]) << 8),
                    reporting: try await reporting(
                        of: cid,
                        via: device,
                        index: index,
                        deviceIndex: deviceIndex,
                        timeout: timeout
                    )
                )
            )
        }
        return controls
    }

    /// The current reporting state of `control`.
    public static func reporting(
        of control: UInt16,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> ControlReporting {
        let request = try FeatureRequest.read(deviceIndex, index, 2, [UInt8(control >> 8), UInt8(control & 0xFF)])
        let reply = try await device.perform(request, timeout: timeout).parameters
        let remap = FeatureRequest.bigEndian(reply[3...4], as: UInt16.self)
        let echoed = FeatureRequest.bigEndian(reply[0...1], as: UInt16.self)
        // A reply for another control must never be mistaken for this one's state.
        guard echoed == control else { throw .deviceError(.invalidArgument) }
        return ControlReporting(
            control: echoed,
            flags: UInt16(reply[2]) | UInt16(reply[5]) << 8,
            remappedTo: remap == 0 ? control : remap
        )
    }
}
