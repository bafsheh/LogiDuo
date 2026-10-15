/// A built-in keyboard shortcut action.
///
/// Mirrors Mouser's macOS shortcut actions; each resolves to a fixed key
/// combination (see ``invocation``).
public enum ShortcutPreset: String, CaseIterable, Hashable, Sendable, Codable {
    /// ⌘⇥ — switch applications.
    case switchApplications
    /// ⌘⇧⇥ — switch applications in reverse.
    case switchApplicationsReverse
    /// ⌘[ — browser back.
    case browserBack
    /// ⌘] — browser forward.
    case browserForward
    /// ⌘C.
    case copy
    /// ⌘V.
    case paste
    /// ⌘X.
    case cut
    /// ⌘Z.
    case undo
    /// ⌘A.
    case selectAll
    /// ⌘S.
    case save
    /// ⌘F.
    case find
    /// ⌘⇧] — next tab.
    case nextTab
    /// ⌘⇧[ — previous tab.
    case previousTab
    /// ⌘W.
    case closeTab
    /// ⌘T.
    case newTab
    /// ⌘= three times.
    case zoomIn
    /// ⌘- three times.
    case zoomOut
    /// Page Up.
    case pageUp
    /// Page Down.
    case pageDown
    /// Home.
    case home
    /// End.
    case end

    /// The key combination and how many times it is sent.
    public var invocation: (shortcut: KeyboardShortcut, repeatCount: Int) {
        switch self {
        case .switchApplications: (KeyboardShortcut(known: .tab, .command), 1)
        case .switchApplicationsReverse: (KeyboardShortcut(known: .tab, [.command, .shift]), 1)
        case .browserBack: (KeyboardShortcut(known: .leftBracket, .command), 1)
        case .browserForward: (KeyboardShortcut(known: .rightBracket, .command), 1)
        case .copy: (KeyboardShortcut(known: .ansiC, .command), 1)
        case .paste: (KeyboardShortcut(known: .ansiV, .command), 1)
        case .cut: (KeyboardShortcut(known: .ansiX, .command), 1)
        case .undo: (KeyboardShortcut(known: .ansiZ, .command), 1)
        case .selectAll: (KeyboardShortcut(known: .ansiA, .command), 1)
        case .save: (KeyboardShortcut(known: .ansiS, .command), 1)
        case .find: (KeyboardShortcut(known: .ansiF, .command), 1)
        case .nextTab: (KeyboardShortcut(known: .rightBracket, [.command, .shift]), 1)
        case .previousTab: (KeyboardShortcut(known: .leftBracket, [.command, .shift]), 1)
        case .closeTab: (KeyboardShortcut(known: .ansiW, .command), 1)
        case .newTab: (KeyboardShortcut(known: .ansiT, .command), 1)
        case .zoomIn: (KeyboardShortcut(known: .equal, .command), 3)
        case .zoomOut: (KeyboardShortcut(known: .minus, .command), 3)
        case .pageUp: (KeyboardShortcut(known: .pageUp), 1)
        case .pageDown: (KeyboardShortcut(known: .pageDown), 1)
        case .home: (KeyboardShortcut(known: .home), 1)
        case .end: (KeyboardShortcut(known: .end), 1)
        }
    }
}

/// Media-key actions.
public enum MediaAction: String, CaseIterable, Hashable, Sendable, Codable {
    /// Volume up.
    case volumeUp
    /// Volume down.
    case volumeDown
    /// Mute.
    case mute
    /// Play or pause.
    case playPause
    /// Next track.
    case nextTrack
    /// Previous track.
    case previousTrack
}

/// What a screenshot captures and where it goes.
public struct ScreenshotAction: Hashable, Sendable, Codable {
    /// The captured area.
    public enum Area: String, CaseIterable, Hashable, Sendable, Codable {
        /// A user-selected region.
        case region
        /// All displays.
        case fullScreen
    }

    /// The destination of the capture.
    public enum Destination: String, CaseIterable, Hashable, Sendable, Codable {
        /// The clipboard.
        case clipboard
        /// A file in the system screenshot location.
        case file
    }

    /// The captured area.
    public let area: Area
    /// The destination.
    public let destination: Destination

    /// Creates a screenshot action.
    public init(area: Area, destination: Destination) {
        self.area = area
        self.destination = destination
    }
}

/// macOS window-management and system actions.
public enum SystemAction: Hashable, Sendable, Codable {
    /// Mission Control.
    case missionControl
    /// App Exposé.
    case appExpose
    /// Show the desktop.
    case showDesktop
    /// Launchpad.
    case launchpad
    /// Move to the Space on the left.
    case previousSpace
    /// Move to the Space on the right.
    case nextSpace
    /// Move through Spaces, reversing at either end.
    case cycleSpaces
    /// Take a screenshot.
    case screenshot(ScreenshotAction)
}

/// Actions that change a setting on the device that triggered them.
public enum DeviceAction: String, CaseIterable, Hashable, Sendable, Codable {
    /// Step to the next pointer resolution preset.
    case cycleResolutionPresets
    /// Turn SmartShift on or off.
    case toggleSmartShift
    /// Switch the wheel between ratchet and free spin.
    case toggleScrollMode
}

/// A mouse button that LogiDuo can synthesize clicks for.
public enum SyntheticButton: String, CaseIterable, Hashable, Sendable, Codable {
    /// Primary click.
    case primary
    /// Secondary click.
    case secondary
    /// Middle click.
    case middle
    /// Back button.
    case back
    /// Forward button.
    case forward

    /// The physical button this click imitates.
    public var button: MouseButton {
        switch self {
        case .primary: .primary
        case .secondary: .secondary
        case .middle: .middle
        case .back: .back
        case .forward: .forward
        }
    }
}

/// An action whose identifier LogiDuo does not understand (for example from a
/// newer or imported configuration). Preserved, never executed.
public struct UnsupportedAction: Hashable, Sendable, Codable {
    /// The original identifier.
    public let identifier: String

    /// Creates a placeholder for an unknown action identifier.
    public init(identifier: String) {
        self.identifier = identifier
    }
}

/// What happens when a trigger fires.
public enum Action: Hashable, Sendable, Codable {
    /// Leave the input untouched: the system handles it natively.
    case passThrough
    /// Synthesize a mouse click.
    case click(SyntheticButton)
    /// Send a built-in shortcut.
    case shortcut(ShortcutPreset)
    /// Send a user-recorded shortcut.
    case customShortcut(KeyboardShortcut)
    /// Send a media key.
    case media(MediaAction)
    /// Perform a system action.
    case system(SystemAction)
    /// Change a setting on the triggering device.
    case device(DeviceAction)
    /// Open or bring forward an application.
    case openApplication(BundleIdentifier)
    /// An unknown action kept for round-tripping; behaves like ``passThrough``.
    case unsupported(UnsupportedAction)

    /// Whether the action leaves the original input to the system.
    public var isPassThrough: Bool {
        switch self {
        case .passThrough, .unsupported: true
        default: false
        }
    }
}
