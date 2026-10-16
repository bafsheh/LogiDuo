import LogiDuoDomain
import SwiftUI

/// Records a key combination for a custom shortcut action.
///
/// Typed keys are recognised through SwiftUI key presses; keys without a
/// character (function keys) are chosen from a list.
struct ShortcutCaptureSheet: View {
    let finish: (LogiDuoDomain.KeyboardShortcut?) -> Void
    @State private var shortcut: LogiDuoDomain.KeyboardShortcut?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("capture.title", bundle: .module).font(.headline)
            field
            Text("capture.hint", bundle: .module).font(.caption).foregroundStyle(.secondary)
            functionKeyPicker
            HStack {
                Button(role: .cancel) {
                    finish(nil)
                } label: {
                    Text("capture.cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    finish(shortcut)
                } label: {
                    Text("capture.save", bundle: .module)
                }
                .disabled(shortcut == nil)
            }
        }
        .padding(24)
        .onAppear { focused = true }
    }

    private var field: some View {
        Text(shortcut?.displayString ?? "—")
            .font(.system(size: 28, weight: .medium, design: .rounded))
            .frame(minWidth: 220, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .focusable()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                guard let captured = ShortcutCapture.shortcut(for: press.key, modifiers: press.modifiers) else {
                    return .ignored
                }
                shortcut = captured
                return .handled
            }
            .accessibilityLabel(Text("capture.field", bundle: .module))
    }

    private var functionKeyPicker: some View {
        Picker(selection: Binding(get: { shortcut?.key }, set: chooseKey)) {
            Text("capture.functionKey.none", bundle: .module).tag(KeyCode?.none)
            ForEach(ShortcutCapture.functionKeys, id: \.self) { key in
                Text(KeyRegistry.entry(for: key)?.name ?? "").tag(KeyCode?.some(key))
            }
        } label: {
            Text("capture.functionKey", bundle: .module)
        }
        .fixedSize()
    }

    private func chooseKey(_ key: KeyCode?) {
        if let key { shortcut = LogiDuoDomain.KeyboardShortcut(key: key, modifiers: shortcut?.modifiers ?? []) }
    }
}

/// Turns a SwiftUI key press into a ``KeyboardShortcut``. Pure.
enum ShortcutCapture {
    /// F1–F20.
    static let functionKeys: [KeyCode] = (1...20).compactMap { KeyRegistry.code(named: "F\($0)") }

    private static let specialKeys: [KeyEquivalent: String] = [
        .upArrow: "↑", .downArrow: "↓", .leftArrow: "←", .rightArrow: "→", .return: "↩", .tab: "⇥",
        .space: "Space", .escape: "⎋", .delete: "⌫", .deleteForward: "⌦", .home: "Home", .end: "End",
        .pageUp: "Page Up", .pageDown: "Page Down",
    ]

    static func shortcut(for key: KeyEquivalent, modifiers: EventModifiers) -> LogiDuoDomain.KeyboardShortcut? {
        let code = specialKeys[key].flatMap(KeyRegistry.code(named:)) ?? KeyRegistry.code(for: key.character)
        guard let code else { return nil }
        var mapped: KeyModifiers = []
        if modifiers.contains(.command) { mapped.insert(.command) }
        if modifiers.contains(.shift) { mapped.insert(.shift) }
        if modifiers.contains(.option) { mapped.insert(.option) }
        if modifiers.contains(.control) { mapped.insert(.control) }
        return LogiDuoDomain.KeyboardShortcut(key: code, modifiers: mapped)
    }
}
