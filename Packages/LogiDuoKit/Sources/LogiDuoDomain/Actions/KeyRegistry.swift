/// Names of the virtual key codes LogiDuo can synthesize (ANSI layout positions).
///
/// Codes are the `kVK_*` values from Carbon's Events.h. Characters are what the key
/// produces on a US layout; they are used to recognise captured keys and to display
/// shortcuts, not to type text.
public enum KeyRegistry {
    /// One key.
    public struct Entry: Hashable, Sendable {
        /// The virtual key code.
        public let code: UInt16
        /// A short display name ("A", "↩", "F5").
        public let name: String
        /// The unshifted character the key types, if any.
        public let character: Character?
    }

    /// Every named key.
    public static let entries: [Entry] = letters + digits + punctuation + special + functionKeys

    private static let letters: [Entry] = [
        ("A", 0x00), ("S", 0x01), ("D", 0x02), ("F", 0x03), ("H", 0x04), ("G", 0x05), ("Z", 0x06), ("X", 0x07),
        ("C", 0x08), ("V", 0x09), ("B", 0x0B), ("Q", 0x0C), ("W", 0x0D), ("E", 0x0E), ("R", 0x0F), ("Y", 0x10),
        ("T", 0x11), ("O", 0x1F), ("U", 0x20), ("I", 0x22), ("P", 0x23), ("L", 0x25), ("J", 0x26), ("K", 0x28),
        ("N", 0x2D), ("M", 0x2E),
    ].map { Entry(code: $0.1, name: $0.0, character: Character($0.0.lowercased())) }

    private static let digits: [Entry] = [
        ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17), ("9", 0x19), ("7", 0x1A),
        ("8", 0x1C), ("0", 0x1D),
    ].map { Entry(code: $0.1, name: $0.0, character: Character($0.0)) }

    private static let punctuation: [Entry] = [
        ("=", 0x18), ("-", 0x1B), ("]", 0x1E), ("[", 0x21), ("'", 0x27), (";", 0x29), ("\\", 0x2A), (",", 0x2B),
        ("/", 0x2C), (".", 0x2F), ("`", 0x32),
    ].map { Entry(code: $0.1, name: $0.0, character: Character($0.0)) }

    private static let special: [Entry] = [
        Entry(code: 0x24, name: "↩", character: "\r"),
        Entry(code: 0x30, name: "⇥", character: "\t"),
        Entry(code: 0x31, name: "Space", character: " "),
        Entry(code: 0x33, name: "⌫", character: "\u{7F}"),
        Entry(code: 0x35, name: "⎋", character: "\u{1B}"),
        Entry(code: 0x75, name: "⌦", character: nil),
        Entry(code: 0x73, name: "Home", character: nil),
        Entry(code: 0x77, name: "End", character: nil),
        Entry(code: 0x74, name: "Page Up", character: nil),
        Entry(code: 0x79, name: "Page Down", character: nil),
        Entry(code: 0x7B, name: "←", character: nil),
        Entry(code: 0x7C, name: "→", character: nil),
        Entry(code: 0x7D, name: "↓", character: nil),
        Entry(code: 0x7E, name: "↑", character: nil),
    ]

    private static let functionKeys: [Entry] = [
        (1, 0x7A), (2, 0x78), (3, 0x63), (4, 0x76), (5, 0x60), (6, 0x61), (7, 0x62), (8, 0x64), (9, 0x65),
        (10, 0x6D), (11, 0x67), (12, 0x6F), (13, 0x69), (14, 0x6B), (15, 0x71), (16, 0x6A), (17, 0x40), (18, 0x4F),
        (19, 0x50), (20, 0x5A),
    ].map { Entry(code: $0.1, name: "F\($0.0)", character: nil) }

    /// The entry for `code`, if named.
    public static func entry(for code: KeyCode) -> Entry? {
        entries.first { $0.code == code.rawValue }
    }

    /// The key that types `character` (case-insensitive), if any.
    public static func code(for character: Character) -> KeyCode? {
        let lowered = Character(character.lowercased())
        return entries.first { $0.character == lowered }.flatMap { KeyCode(rawValue: $0.code) }
    }

    /// The key named `name` ("F5", "↩", "Page Up"), if any.
    public static func code(named name: String) -> KeyCode? {
        entries.first { $0.name.lowercased() == name.lowercased() }.flatMap { KeyCode(rawValue: $0.code) }
    }
}

extension KeyboardShortcut {
    /// The shortcut as macOS shows it, for example "⌃⌥⇧⌘A".
    public var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        let key = KeyRegistry.entry(for: key)?.name ?? "Key \(key.rawValue)"
        return symbols + key
    }
}
