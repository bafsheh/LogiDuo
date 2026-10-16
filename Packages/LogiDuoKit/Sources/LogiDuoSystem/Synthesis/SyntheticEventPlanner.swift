public import LogiDuoDomain

/// A media key, identified by its `NX_KEYTYPE_*` value.
public enum MediaKey: Int, Hashable, Sendable {
    /// `NX_KEYTYPE_SOUND_UP`.
    case volumeUp = 0
    /// `NX_KEYTYPE_SOUND_DOWN`.
    case volumeDown = 1
    /// `NX_KEYTYPE_MUTE`.
    case mute = 7
    /// `NX_KEYTYPE_PLAY`.
    case playPause = 16
    /// `NX_KEYTYPE_NEXT`.
    case nextTrack = 17
    /// `NX_KEYTYPE_PREVIOUS`.
    case previousTrack = 18
}

/// One synthetic event to post, independent of CoreGraphics.
public enum SyntheticEventSpec: Hashable, Sendable {
    /// A mouse button transition.
    case mouseButton(SyntheticButton, isDown: Bool)
    /// A key transition; modifiers are applied as event flags on the down only (as in Mouser).
    case key(KeyCode, isDown: Bool, modifiers: KeyModifiers)
    /// A media key transition.
    case mediaKey(MediaKey, isDown: Bool)
    /// Open or bring forward an application.
    case openApplication(BundleIdentifier)
}

/// Why a command was not turned into events.
public enum SyntheticPlanGap: Hashable, Sendable {
    /// Device actions need HID++ writes, which Phase 4 does not perform.
    case requiresDeviceConfiguration(DeviceAction)
    /// Cycling Spaces needs the current Space, which only private APIs expose.
    case requiresPrivateAPI
    /// Only system-reported buttons can be replayed as native clicks.
    case notReplayable(MouseButton)
}

/// The events for one command, or why there are none.
public struct SyntheticPlan: Hashable, Sendable {
    /// Events to post, in order.
    public let events: [SyntheticEventSpec]
    /// Why the command could not be performed, if it could not.
    public let gap: SyntheticPlanGap?

    static func events(_ events: [SyntheticEventSpec]) -> SyntheticPlan { SyntheticPlan(events: events, gap: nil) }
    static func gap(_ gap: SyntheticPlanGap) -> SyntheticPlan { SyntheticPlan(events: [], gap: gap) }
}

/// Turns input commands into synthetic events using only public, documented mechanisms.
///
/// System actions use macOS's default keyboard shortcuts (the same fallbacks
/// Mouser uses when private Dock calls fail); they depend on the user keeping
/// those shortcuts enabled in System Settings › Keyboard › Keyboard Shortcuts.
/// Every key down is immediately followed by its key up, so no key can stay down.
public enum SyntheticEventPlanner {
    /// The events for `command`.
    public static func plan(_ command: InputCommand) -> SyntheticPlan {
        switch command {
        case .pressSynthetic(let button): .events([.mouseButton(button, isDown: true)])
        case .releaseSynthetic(let button): .events([.mouseButton(button, isDown: false)])
        case .replayNativeClick(let button): replay(button)
        case .perform(let action): plan(action)
        }
    }

    private static func replay(_ button: MouseButton) -> SyntheticPlan {
        guard let synthetic = SyntheticButton(rawValue: button.rawValue), button.isSystemReported else {
            return .gap(.notReplayable(button))
        }
        return .events([.mouseButton(synthetic, isDown: true), .mouseButton(synthetic, isDown: false)])
    }

    private static func plan(_ action: Action) -> SyntheticPlan {
        switch action {
        case .passThrough, .unsupported:
            .events([])
        case .click(let button):
            .events([.mouseButton(button, isDown: true), .mouseButton(button, isDown: false)])
        case .shortcut(let preset):
            .events(keystrokes(preset.invocation.shortcut, repeat: preset.invocation.repeatCount))
        case .customShortcut(let shortcut):
            .events(keystrokes(shortcut, repeat: 1))
        case .media(let media):
            .events(tap(mediaKey(media)))
        case .system(let systemAction):
            plan(systemAction)
        case .device(let device):
            .gap(.requiresDeviceConfiguration(device))
        case .openApplication(let bundle):
            .events([.openApplication(bundle)])
        }
    }

    private static func plan(_ action: SystemAction) -> SyntheticPlan {
        let control = KeyModifiers.control
        switch action {
        case .missionControl: return .events(keystrokes(code(0x7E), control))
        case .appExpose: return .events(keystrokes(code(0x7D), control))
        case .showDesktop: return .events(keystrokes(code(0x67), []))
        case .launchpad: return .events(keystrokes(code(0x76), []))
        case .previousSpace: return .events(keystrokes(code(0x7B), control))
        case .nextSpace: return .events(keystrokes(code(0x7C), control))
        case .cycleSpaces: return .gap(.requiresPrivateAPI)
        case .screenshot(let screenshot):
            let key = code(screenshot.area == .region ? 0x15 : 0x14)
            var modifiers: KeyModifiers = [.command, .shift]
            if screenshot.destination == .clipboard { modifiers.insert(.control) }
            return .events(keystrokes(key, modifiers))
        }
    }

    private static func keystrokes(_ key: KeyCode, _ modifiers: KeyModifiers) -> [SyntheticEventSpec] {
        [.key(key, isDown: true, modifiers: modifiers), .key(key, isDown: false, modifiers: modifiers)]
    }

    private static func keystrokes(_ shortcut: KeyboardShortcut, repeat count: Int) -> [SyntheticEventSpec] {
        (0..<max(1, count)).flatMap { _ in keystrokes(shortcut.key, shortcut.modifiers) }
    }

    private static func tap(_ key: MediaKey) -> [SyntheticEventSpec] {
        [.mediaKey(key, isDown: true), .mediaKey(key, isDown: false)]
    }

    private static func mediaKey(_ media: MediaAction) -> MediaKey {
        switch media {
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .mute: .mute
        case .playPause: .playPause
        case .nextTrack: .nextTrack
        case .previousTrack: .previousTrack
        }
    }

    /// Key codes used here are fixed macOS virtual key codes (arrows, F4, F11, 3, 4).
    private static func code(_ raw: UInt16) -> KeyCode {
        guard let code = KeyCode(rawValue: raw) else { preconditionFailure("\(raw) is a valid key code") }
        return code
    }
}
