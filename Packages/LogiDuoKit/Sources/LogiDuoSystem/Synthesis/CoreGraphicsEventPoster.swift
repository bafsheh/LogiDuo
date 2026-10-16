import AppKit
import CoreGraphics
import LogiDuoDomain

/// Posts synthetic events through CoreGraphics, marked with ``SyntheticEventMarker``.
///
/// Events use a private event source, so their modifier flags never become part
/// of the system's combined modifier state, and are posted at the HID level like
/// physical input; LogiDuo's own tap recognises the marker and passes them on.
public struct CoreGraphicsEventPoster: SyntheticEventPosting {
    /// Creates a poster.
    public init() {}

    /// Posts `spec`.
    public func post(_ spec: SyntheticEventSpec) {
        switch spec {
        case .mouseButton(let button, let isDown): postMouse(button, isDown: isDown)
        case .key(let key, let isDown, let modifiers): postKey(key, isDown: isDown, modifiers: modifiers)
        case .mediaKey(let key, let isDown): postMedia(key, isDown: isDown)
        case .openApplication(let bundle): open(bundle)
        }
    }

    private var source: CGEventSource? { CGEventSource(stateID: .privateState) }

    private func postMouse(_ button: SyntheticButton, isDown: Bool) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let (type, cgButton, number): (CGEventType, CGMouseButton, Int64) =
            switch button {
            case .primary: (isDown ? .leftMouseDown : .leftMouseUp, .left, 0)
            case .secondary: (isDown ? .rightMouseDown : .rightMouseUp, .right, 1)
            case .middle: (isDown ? .otherMouseDown : .otherMouseUp, .center, 2)
            case .back: (isDown ? .otherMouseDown : .otherMouseUp, .center, 3)
            case .forward: (isDown ? .otherMouseDown : .otherMouseUp, .center, 4)
            }
        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: cgButton
            )
        else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        mark(event).post(tap: .cghidEventTap)
    }

    private func postKey(_ key: KeyCode, isDown: Bool, modifiers: KeyModifiers) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: isDown) else {
            return
        }
        event.flags = isDown ? Self.flags(modifiers) : []
        mark(event).post(tap: .cghidEventTap)
    }

    private func postMedia(_ key: MediaKey, isDown: Bool) {
        let data1 = (key.rawValue << 16) | ((isDown ? 0xA : 0xB) << 8)
        guard
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent
        else { return }
        mark(event).post(tap: .cghidEventTap)
    }

    private func open(_ bundle: BundleIdentifier) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle.value) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func mark(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        return event
    }

    static func flags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}
