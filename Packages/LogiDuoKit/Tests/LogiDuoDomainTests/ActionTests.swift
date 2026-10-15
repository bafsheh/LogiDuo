import Foundation
import LogiDuoDomain
import Testing

@Suite("Keyboard shortcuts and presets")
struct ShortcutTests {
    struct PresetCase: Sendable, CustomTestStringConvertible {
        let preset: ShortcutPreset
        let key: UInt16
        let modifiers: KeyModifiers
        let repeats: Int

        init(_ preset: ShortcutPreset, key: UInt16, modifiers: KeyModifiers, repeats: Int) {
            self.preset = preset
            self.key = key
            self.modifiers = modifiers
            self.repeats = repeats
        }

        var testDescription: String { preset.rawValue }
    }

    static let presetCases: [PresetCase] = [
        PresetCase(.switchApplications, key: 0x30, modifiers: .command, repeats: 1),
        PresetCase(.switchApplicationsReverse, key: 0x30, modifiers: [.command, .shift], repeats: 1),
        PresetCase(.browserBack, key: 0x21, modifiers: .command, repeats: 1),
        PresetCase(.browserForward, key: 0x1E, modifiers: .command, repeats: 1),
        PresetCase(.copy, key: 0x08, modifiers: .command, repeats: 1),
        PresetCase(.paste, key: 0x09, modifiers: .command, repeats: 1),
        PresetCase(.cut, key: 0x07, modifiers: .command, repeats: 1),
        PresetCase(.undo, key: 0x06, modifiers: .command, repeats: 1),
        PresetCase(.selectAll, key: 0x00, modifiers: .command, repeats: 1),
        PresetCase(.save, key: 0x01, modifiers: .command, repeats: 1),
        PresetCase(.find, key: 0x03, modifiers: .command, repeats: 1),
        PresetCase(.nextTab, key: 0x1E, modifiers: [.command, .shift], repeats: 1),
        PresetCase(.previousTab, key: 0x21, modifiers: [.command, .shift], repeats: 1),
        PresetCase(.closeTab, key: 0x0D, modifiers: .command, repeats: 1),
        PresetCase(.newTab, key: 0x11, modifiers: .command, repeats: 1),
        PresetCase(.zoomIn, key: 0x18, modifiers: .command, repeats: 3),
        PresetCase(.zoomOut, key: 0x1B, modifiers: .command, repeats: 3),
        PresetCase(.pageUp, key: 0x74, modifiers: [], repeats: 1),
        PresetCase(.pageDown, key: 0x79, modifiers: [], repeats: 1),
        PresetCase(.home, key: 0x73, modifiers: [], repeats: 1),
        PresetCase(.end, key: 0x77, modifiers: [], repeats: 1),
    ]

    @Test("presets send Mouser's macOS key combinations", arguments: presetCases)
    func presetInvocation(testCase: PresetCase) {
        let invocation = testCase.preset.invocation
        #expect(invocation.shortcut.key.rawValue == testCase.key)
        #expect(invocation.shortcut.modifiers == testCase.modifiers)
        #expect(invocation.repeatCount == testCase.repeats)
    }

    @Test("every preset is covered by the table above")
    func presetCoverage() {
        #expect(Set(Self.presetCases.map(\.preset)) == Set(ShortcutPreset.allCases))
    }

    @Test("key codes above 0x7F are rejected")
    func keyCodeRange() {
        #expect(KeyCode(rawValue: 0x7F) != nil)
        #expect(KeyCode(rawValue: 0x80) == nil)
    }

    @Test("a modifier key cannot be the pressed key", arguments: UInt16(0x36)...UInt16(0x3F))
    func modifierKeyRejected(code: UInt16) throws {
        let key = try #require(KeyCode(rawValue: code))
        #expect(key.isModifier)
        #expect(KeyboardShortcut(key: key, modifiers: .command) == nil)
    }

    @Test("a plain key without modifiers is a valid shortcut")
    func bareKey() throws {
        let space = try #require(KeyCode(rawValue: 0x31))
        let shortcut = try #require(KeyboardShortcut(key: space, modifiers: []))
        #expect(shortcut.modifiers.isEmpty)
    }

    @Test("unknown modifier bits are discarded")
    func modifierBits() {
        #expect(KeyModifiers(rawValue: 0xFF) == [.command, .shift, .option, .control])
    }
}

@Suite("BundleIdentifier")
struct BundleIdentifierTests {
    @Test("compares case-insensitively and keeps the original spelling")
    func caseInsensitive() throws {
        let mixed = try #require(BundleIdentifier("com.Apple.Safari"))
        let lower = try #require(BundleIdentifier("com.apple.safari"))

        #expect(mixed == lower)
        #expect(Set([mixed, lower]).count == 1)
        #expect(mixed.description == "com.Apple.Safari")
    }

    @Test(
        "rejects malformed identifiers",
        arguments: ["", "com..apple", ".com.apple", "com.apple.", "com apple", "com/apple", "cöm.apple"]
    )
    func rejectsMalformed(value: String) {
        #expect(BundleIdentifier(value) == nil)
    }

    @Test("accepts hyphens and digits")
    func acceptsHyphensAndDigits() {
        #expect(BundleIdentifier("org.mozilla.firefox-2") != nil)
    }

    @Test("decoding validates the identifier")
    func decoding() throws {
        let decoded = try JSONDecoder().decode(BundleIdentifier.self, from: Data("\"com.apple.Music\"".utf8))
        #expect(decoded == BundleIdentifier("com.apple.music"))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BundleIdentifier.self, from: Data("\"bad id\"".utf8))
        }
    }
}

@Suite("Action")
struct ActionTests {
    @Test("only pass-through and unsupported actions leave input to the system")
    func passThroughSemantics() {
        #expect(Action.passThrough.isPassThrough)
        #expect(Action.unsupported(UnsupportedAction(identifier: "activate_actions_ring")).isPassThrough)
        #expect(!Action.click(.middle).isPassThrough)
        #expect(!Action.system(.missionControl).isPassThrough)
    }

    @Test("synthetic clicks imitate the matching physical button", arguments: SyntheticButton.allCases)
    func syntheticButtons(button: SyntheticButton) {
        #expect(button.button.rawValue == button.rawValue)
        #expect(button.button.isSystemReported)
    }
}
