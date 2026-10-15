/// A macOS virtual key code (the `kVK_*` values), independent of keyboard layout.
public struct KeyCode: RawRepresentable, Hashable, Sendable, Codable {
    /// The highest virtual key code macOS defines.
    public static let maximumRawValue: UInt16 = 0x7F

    /// Key codes of the modifier keys themselves (Command, Shift, Caps Lock,
    /// Option, Control, their right-hand variants, and Fn).
    static let modifierKeyCodes: Set<UInt16> = Set(0x36...0x3F)

    /// The virtual key code.
    public let rawValue: UInt16

    /// Creates a key code, rejecting values above ``maximumRawValue``.
    public init?(rawValue: UInt16) {
        guard rawValue <= Self.maximumRawValue else { return nil }
        self.rawValue = rawValue
    }

    /// Whether this is a modifier key rather than a key that can be "pressed" in a shortcut.
    public var isModifier: Bool { Self.modifierKeyCodes.contains(rawValue) }
}

extension KeyCode {
    // Constants used by built-in shortcuts. Values are the `kVK_ANSI_*` and
    // `kVK_*` codes from Carbon's Events.h; they are layout-independent
    // positions on an ANSI keyboard.
    static let ansiA = KeyCode(known: 0x00)
    static let ansiS = KeyCode(known: 0x01)
    static let ansiF = KeyCode(known: 0x03)
    static let ansiZ = KeyCode(known: 0x06)
    static let ansiX = KeyCode(known: 0x07)
    static let ansiC = KeyCode(known: 0x08)
    static let ansiV = KeyCode(known: 0x09)
    static let ansiW = KeyCode(known: 0x0D)
    static let ansiT = KeyCode(known: 0x11)
    static let equal = KeyCode(known: 0x18)
    static let minus = KeyCode(known: 0x1B)
    static let rightBracket = KeyCode(known: 0x1E)
    static let leftBracket = KeyCode(known: 0x21)
    static let tab = KeyCode(known: 0x30)
    static let home = KeyCode(known: 0x73)
    static let pageUp = KeyCode(known: 0x74)
    static let end = KeyCode(known: 0x77)
    static let pageDown = KeyCode(known: 0x79)

    private init(known rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

/// Modifier keys held during a shortcut.
public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    /// Command (⌘).
    public static let command = KeyModifiers(rawValue: 1 << 0)
    /// Shift (⇧).
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    /// Option (⌥).
    public static let option = KeyModifiers(rawValue: 1 << 2)
    /// Control (⌃).
    public static let control = KeyModifiers(rawValue: 1 << 3)

    /// The modifier bits.
    public let rawValue: UInt8

    /// Creates a modifier set from raw bits; unknown bits are discarded.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0b1111
    }
}

/// A key combination to synthesize.
public struct KeyboardShortcut: Hashable, Sendable, Codable {
    /// The key pressed while ``modifiers`` are held.
    public let key: KeyCode
    /// The held modifiers; may be empty for keys such as Page Up.
    public let modifiers: KeyModifiers

    /// Creates a shortcut, rejecting a modifier key as the pressed key.
    public init?(key: KeyCode, modifiers: KeyModifiers) {
        guard !key.isModifier else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    init(known key: KeyCode, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}
