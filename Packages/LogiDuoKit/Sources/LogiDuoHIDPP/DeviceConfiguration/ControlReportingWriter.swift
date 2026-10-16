/// The only setCidReporting (ReprogControlsV4 fn3) commands LogiDuo can send.
///
/// Byte values match the commands Mouser has used in the field (audit vectors
/// V16–V18). The flags byte layout is:
/// ```
/// bit 0 divert        bit 1 divert valid
/// bit 2 persist       bit 3 persist valid      ← never set: no case can express it
/// bit 4 raw XY        bit 5 raw XY valid
/// bits 6–7 force raw XY (and valid)            ← never set
/// ```
/// A value bit only takes effect with its valid bit, so each command changes
/// exactly the state it names. Request: `[cid hi, cid lo, flags, 0x00, 0x00]`
/// (remap 0 = leave remapping unchanged).
public enum ReportingCommand: Hashable, Sendable, CaseIterable {
    /// Divert presses only (`0x03`).
    case divertButtonOnly
    /// Divert presses and raw XY movement (`0x33`).
    case divertWithRawXY
    /// Undo a button-only divert (`0x02`).
    case undivertButtonOnly
    /// Undo a raw-XY divert (`0x22`).
    case undivertWithRawXY

    /// The setCidReporting flags byte.
    public var flagsByte: UInt8 {
        switch self {
        case .divertButtonOnly: 0x03
        case .divertWithRawXY: 0x33
        case .undivertButtonOnly: 0x02
        case .undivertWithRawXY: 0x22
        }
    }

    /// Whether the command diverts.
    public var diverts: Bool { self == .divertButtonOnly || self == .divertWithRawXY }

    /// The command that returns a control in state `current` to native reporting.
    public static func undivert(from current: ControlReporting) -> ReportingCommand {
        current.isRawXYDiverted ? .undivertWithRawXY : .undivertButtonOnly
    }

    /// Checks the command is supported by `control`.
    /// - Throws: ``DeviceConfigurationError`` for protected, non-divertable or raw-XY-incapable controls.
    public func validate(for control: ReprogrammableControl) throws(DeviceConfigurationError) {
        guard control.flags.contains(.divertable) else { throw .notDivertable(control.control) }
        if self == .divertWithRawXY, !control.flags.contains(.rawXY) {
            throw .unsupportedCombination(control.control)
        }
    }

    /// Whether `reporting` is exactly the state this command produces.
    public func isSatisfied(by reporting: ControlReporting) -> Bool {
        switch self {
        case .divertButtonOnly: reporting.flags == 0x0001
        case .divertWithRawXY: reporting.flags == 0x0011
        case .undivertButtonOnly, .undivertWithRawXY: reporting.flags == 0
        }
    }
}

extension ReprogControlsFeature {
    /// Sends one setCidReporting command. A **write**.
    /// - Throws: ``DeviceConfigurationError/unexpectedResponse(_:)`` if the reply does not echo `control`.
    public static func send(
        _ command: ReportingCommand,
        to control: UInt16,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(DeviceConfigurationError) {
        let request: HIDPPRequest
        do {
            request = try HIDPPRequest(
                deviceIndex: deviceIndex,
                featureIndex: index,
                function: FunctionID(nibble: 3),
                parameters: [UInt8(control >> 8), UInt8(control & 0xFF), command.flagsByte, 0x00, 0x00],
                kind: .write
            )
        } catch {
            throw .request(.framing(error))
        }
        let reply: HIDPPMessage
        do {
            reply = try await device.perform(request, timeout: timeout)
        } catch {
            throw .request(error)
        }
        guard FeatureRequest.bigEndian(reply.parameters[0...1], as: UInt16.self) == control else {
            throw .unexpectedResponse(control)
        }
    }
}
