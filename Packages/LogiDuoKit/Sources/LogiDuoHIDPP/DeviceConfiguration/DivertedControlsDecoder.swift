public import LogiDuoDomain

/// Turns ReprogControlsV4 notifications into input events. Pure value type.
///
/// ```
/// fn0 divertedButtonsEvent → [cid(2) × up to 4, 0x0000 terminated]   every currently pressed diverted control
/// fn1 divertedRawXYEvent   → [dx(2, signed), dy(2, signed)]
/// ```
/// Presses and releases are the difference between consecutive pressed sets, so a
/// lost notification can never leave a button logically held after the next one.
public struct DivertedControlsDecoder: Hashable, Sendable {
    /// The controls LogiDuo diverts and the buttons they stand for.
    public static let buttons: [UInt16: MouseButton] = [
        0x00C3: .gesture,
        0x00D7: .gesture,
        0x00C4: .modeShift,
        0x00FD: .dpiSwitch,
    ]

    /// The control identifier of `button`, if LogiDuo can divert it.
    public static func control(for button: MouseButton) -> UInt16? {
        switch button {
        case .gesture: 0x00C3
        case .modeShift: 0x00C4
        case .dpiSwitch: 0x00FD
        default: nil
        }
    }

    private var pressed: Set<MouseButton> = []

    /// Creates a decoder with nothing pressed.
    public init() {}

    /// The events for one ReprogControlsV4 notification.
    public mutating func decode(function: UInt8, parameters: [UInt8]) -> [InputEvent] {
        switch function {
        case 0:
            var now: Set<MouseButton> = []
            var offset = 0
            while offset + 1 < min(parameters.count, 8) {
                let cid = UInt16(parameters[offset]) << 8 | UInt16(parameters[offset + 1])
                if cid == 0 { break }
                if let button = Self.buttons[cid] { now.insert(button) }
                offset += 2
            }
            let released = pressed.subtracting(now).sorted { $0.rawValue < $1.rawValue }.map(InputEvent.buttonUp)
            let down = now.subtracting(pressed).sorted { $0.rawValue < $1.rawValue }.map(InputEvent.buttonDown)
            pressed = now
            return released + down
        case 1:
            guard parameters.count >= 4 else { return [] }
            let dx = Int16(bitPattern: UInt16(parameters[0]) << 8 | UInt16(parameters[1]))
            let dy = Int16(bitPattern: UInt16(parameters[2]) << 8 | UInt16(parameters[3]))
            guard dx != 0 || dy != 0 else { return [] }
            return [.motion(dx: Double(dx), dy: Double(dy), source: .deviceRawXY)]
        default:
            return []
        }
    }

    /// Releases for everything still pressed (for example when the device disconnects).
    public mutating func releaseAll() -> [InputEvent] {
        defer { pressed = [] }
        return pressed.sorted { $0.rawValue < $1.rawValue }.map(InputEvent.buttonUp)
    }
}
