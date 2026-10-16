import Foundation

/// Translates Mouser mapping keys and macOS action identifiers into LogiDuo mappings. Pure.
enum MouserMappingTranslator {
    /// Mouser button keys and the buttons they stand for.
    static let buttons: [String: MouseButton] = [
        "middle": .middle, "xbutton1": .back, "xbutton2": .forward, "gesture": .gesture,
        "mode_shift": .modeShift, "dpi_switch": .dpiSwitch, "thumb_button": .thumb,
    ]

    /// Buttons LogiDuo does not map yet (MX Master 4 Sense Panel / Actions Ring).
    static let unsupportedButtons: Set<String> = ["actions_ring"]

    static let directions: [String: SwipeDirection] = ["left": .left, "right": .right, "up": .up, "down": .down]

    /// Mouser's macOS action identifiers.
    static let actions: [String: Action] = [
        "alt_tab": .shortcut(.switchApplications), "alt_shift_tab": .shortcut(.switchApplicationsReverse),
        "browser_back": .shortcut(.browserBack), "browser_forward": .shortcut(.browserForward),
        "copy": .shortcut(.copy), "paste": .shortcut(.paste), "cut": .shortcut(.cut), "undo": .shortcut(.undo),
        "select_all": .shortcut(.selectAll), "save": .shortcut(.save), "find": .shortcut(.find),
        "next_tab": .shortcut(.nextTab), "prev_tab": .shortcut(.previousTab), "close_tab": .shortcut(.closeTab),
        "new_tab": .shortcut(.newTab), "zoom_in": .shortcut(.zoomIn), "zoom_out": .shortcut(.zoomOut),
        "page_up": .shortcut(.pageUp), "page_down": .shortcut(.pageDown), "home": .shortcut(.home),
        "end": .shortcut(.end),
        "volume_up": .media(.volumeUp), "volume_down": .media(.volumeDown), "volume_mute": .media(.mute),
        "play_pause": .media(.playPause), "next_track": .media(.nextTrack), "prev_track": .media(.previousTrack),
        "mission_control": .system(.missionControl), "app_expose": .system(.appExpose),
        "show_desktop": .system(.showDesktop), "launchpad": .system(.launchpad),
        "space_left": .system(.previousSpace), "space_right": .system(.nextSpace),
        "screenshot_region_clip": .system(.screenshot(ScreenshotAction(area: .region, destination: .clipboard))),
        "screenshot_region_file": .system(.screenshot(ScreenshotAction(area: .region, destination: .file))),
        "screenshot_full_clip": .system(.screenshot(ScreenshotAction(area: .fullScreen, destination: .clipboard))),
        "screenshot_full_file": .system(.screenshot(ScreenshotAction(area: .fullScreen, destination: .file))),
        "mouse_left_click": .click(.primary), "mouse_right_click": .click(.secondary),
        "mouse_middle_click": .click(.middle), "mouse_back_click": .click(.back),
        "mouse_forward_click": .click(.forward),
        "cycle_dpi": .device(.cycleResolutionPresets), "toggle_smart_shift": .device(.toggleSmartShift),
        "switch_scroll_mode": .device(.toggleScrollMode),
    ]

    /// The action for a Mouser identifier: `.passThrough` for "none", `nil` if unsupported.
    static func action(_ identifier: String) -> Action? {
        if identifier == "none" { return .passThrough }
        if identifier.hasPrefix("custom:") {
            return customShortcut(String(identifier.dropFirst(7))).map(Action.customShortcut)
        }
        return actions[identifier]
    }

    /// Parses Mouser's `ctrl+shift+a` combos.
    static func customShortcut(_ combo: String) -> KeyboardShortcut? {
        var modifiers: KeyModifiers = []
        var key: KeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "super", "cmd", "command", "meta", "win", "windows": modifiers.insert(.command)
            default:
                guard key == nil, let code = keyCode(part) else { return nil }
                key = code
            }
        }
        return key.flatMap { KeyboardShortcut(key: $0, modifiers: modifiers) }
    }

    private static let keyNames: [String: String] = [
        "tab": "⇥", "space": "Space", "enter": "↩", "return": "↩", "esc": "⎋", "escape": "⎋", "backspace": "⌫",
        "delete": "⌦", "del": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓", "pageup": "Page Up",
        "pagedown": "Page Down", "home": "Home", "end": "End", "grave": "`", "minus": "-", "equal": "=",
        "leftbracket": "[", "rightbracket": "]", "backslash": "\\", "semicolon": ";", "quote": "'", "comma": ",",
        "period": ".", "slash": "/",
    ]

    private static func keyCode(_ name: String) -> KeyCode? {
        if let mapped = keyNames[name] { return KeyRegistry.code(named: mapped) }
        if name.count == 1, let character = name.first { return KeyRegistry.code(for: character) }
        return KeyRegistry.code(named: name)  // f1…f20
    }

    /// Mappings for one Mouser profile.
    static func translate(_ raw: [String: Any], notes: inout [MouserImportNote]) -> [ButtonMapping] {
        var result: [ButtonMapping] = []
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
            guard let identifier = value as? String, let trigger = trigger(for: key, in: raw) else {
                if let base = key.split(separator: "_").first.map(String.init),
                    unsupportedButtons.contains(base) || unsupportedButtons.contains(key),
                    (value as? String).map({ $0 != "none" }) == true
                {
                    notes.append(.unsupportedButton(key))
                }
                continue
            }
            guard identifier != "gesture_swipe" else { continue }
            guard let action = action(identifier) else {
                notes.append(.unsupportedAction(button: key, action: identifier))
                continue
            }
            // A button clicking itself is its native behavior (Mouser's back/forward defaults).
            if case .click(let clicked) = action, trigger == .press(clicked.button) { continue }
            guard action != .passThrough else { continue }
            result.append(ButtonMapping(trigger: trigger, action: action))
        }
        return result
    }

    /// The trigger for a Mouser key, honouring the gesture-swipe sentinel.
    private static func trigger(for key: String, in raw: [String: Any]) -> InputTrigger? {
        if let button = buttons[key] {
            // A gesture-swipe button's click comes from "<button>_tap".
            return raw[key] as? String == "gesture_swipe" ? nil : .press(button)
        }
        if key == "hscroll_left" { return .horizontalScroll(.left) }
        if key == "hscroll_right" { return .horizontalScroll(.right) }
        guard let separator = key.lastIndex(of: "_") else { return nil }
        let base = String(key[..<separator])
        let suffix = String(key[key.index(after: separator)...])
        guard let button = buttons[base] else { return nil }
        if suffix == "tap" { return raw[base] as? String == "gesture_swipe" ? .press(button) : nil }
        return directions[suffix].map { InputTrigger.swipe(button, $0) }
    }

    /// Leaves out mappings that would break the mapping rules (click loops), so the rest still import.
    static func resolvingConflicts(
        defaults: [ButtonMapping],
        profiles: [StoredProfile],
        notes: inout [MouserImportNote]
    ) -> ([ButtonMapping], [StoredProfile]) {
        let validDefaults = admitted(defaults, notes: &notes) { (try? MappingSet($0)) != nil }
        guard let defaultSet = try? MappingSet(validDefaults) else { return ([], profiles) }
        let validProfiles = profiles.map { profile in
            var profile = profile
            profile.mappings = admitted(profile.mappings, notes: &notes) { candidate in
                guard let overrides = try? MappingSet(candidate),
                    let application = ApplicationProfile(
                        id: profile.id,
                        name: profile.name,
                        matchers: profile.matchers,
                        overrides: overrides
                    )
                else { return false }
                return (try? ProfileSet(defaultMappings: defaultSet, applicationProfiles: [application])) != nil
            }
            return profile
        }
        return (validDefaults, validProfiles)
    }

    private static func admitted(
        _ mappings: [ButtonMapping],
        notes: inout [MouserImportNote],
        isValid: ([ButtonMapping]) -> Bool
    ) -> [ButtonMapping] {
        var kept: [ButtonMapping] = []
        for mapping in mappings {
            if isValid(kept + [mapping]) {
                kept.append(mapping)
            } else {
                notes.append(.conflictingMapping(button: "\(mapping.trigger)"))
            }
        }
        return kept
    }
}
