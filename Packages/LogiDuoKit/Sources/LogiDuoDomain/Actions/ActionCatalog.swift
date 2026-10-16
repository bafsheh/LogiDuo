/// How actions are grouped in the action picker.
public enum ActionCategory: String, CaseIterable, Hashable, Sendable {
    case native
    case mouse
    case navigation
    case editing
    case tabs
    case media
    case system
    case screenshots
    case device
}

/// One action the person can pick, with a stable identifier for the interface.
public struct ActionChoice: Hashable, Sendable, Identifiable {
    /// A stable identifier, for example `shortcut.copy`.
    public let id: String
    /// The action.
    public let action: Action
    /// Its group.
    public let category: ActionCategory
}

/// Every fixed action, grouped. Custom shortcuts and opening an application are
/// parameterized and edited separately.
public enum ActionCatalog {
    /// All choices, in display order.
    public static let choices: [ActionChoice] = {
        var choices = [ActionChoice(id: "native", action: .passThrough, category: .native)]
        choices += SyntheticButton.allCases.map { button in
            ActionChoice(id: "click.\(button.rawValue)", action: .click(button), category: .mouse)
        }
        choices += ShortcutPreset.allCases.map { preset in
            ActionChoice(id: "shortcut.\(preset.rawValue)", action: .shortcut(preset), category: category(of: preset))
        }
        choices += MediaAction.allCases.map { media in
            ActionChoice(id: "media.\(media.rawValue)", action: .media(media), category: .media)
        }
        let system: [(String, SystemAction)] = [
            ("missionControl", .missionControl), ("appExpose", .appExpose), ("showDesktop", .showDesktop),
            ("launchpad", .launchpad), ("previousSpace", .previousSpace), ("nextSpace", .nextSpace),
        ]
        choices += system.map { ActionChoice(id: "system.\($0.0)", action: .system($0.1), category: .system) }
        for area in ScreenshotAction.Area.allCases {
            for destination in ScreenshotAction.Destination.allCases {
                choices.append(
                    ActionChoice(
                        id: "screenshot.\(area.rawValue).\(destination.rawValue)",
                        action: .system(.screenshot(ScreenshotAction(area: area, destination: destination))),
                        category: .screenshots
                    )
                )
            }
        }
        choices += DeviceAction.allCases.map { device in
            ActionChoice(id: "device.\(device.rawValue)", action: .device(device), category: .device)
        }
        return choices
    }()

    /// The choice for `action`, if it is a fixed one.
    public static func choice(for action: Action) -> ActionChoice? {
        choices.first { $0.action == action }
    }

    /// The choices of one category.
    public static func choices(in category: ActionCategory) -> [ActionChoice] {
        choices.filter { $0.category == category }
    }

    private static func category(of preset: ShortcutPreset) -> ActionCategory {
        switch preset {
        case .switchApplications, .switchApplicationsReverse, .browserBack, .browserForward, .pageUp, .pageDown,
            .home, .end:
            .navigation
        case .copy, .paste, .cut, .undo, .selectAll, .save, .find, .zoomIn, .zoomOut:
            .editing
        case .nextTab, .previousTab, .closeTab, .newTab:
            .tabs
        }
    }
}
