public import SwiftUI

/// The remapping controls in the menu-bar menu: always present, so remapping can always be turned off.
public struct RemappingMenuSection: View {
    @Bindable private var model: RemappingViewModel

    /// Creates the section.
    public init(model: RemappingViewModel) {
        self.model = model
    }

    public var body: some View {
        Toggle(isOn: $model.isEnabled) {
            Text("menu.remapping", bundle: .module)
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .accessibilityIdentifier("menu.remapping")

        Text(LocalizedStringKey(model.statusKey), bundle: .module)
        if let profile = model.status.activeProfileName {
            Text("remapping.activeProfile \(profile)", bundle: .module)
        }

        if model.offersPermissionSettings {
            Button {
                model.openPermissionSettings()
            } label: {
                Text("remapping.openAccessibilitySettings", bundle: .module)
            }
        }

        Picker(selection: Binding(get: { model.status.preset }, set: { model.select($0) })) {
            ForEach(ValidationPreset.allCases) { preset in
                Text(preset.titleKey, bundle: .module).tag(preset)
            }
        } label: {
            Text("remapping.preset", bundle: .module)
        }
    }
}

extension ValidationPreset {
    var titleKey: LocalizedStringKey {
        switch self {
        case .configured: "remapping.preset.configured"
        case .observeOnly: "remapping.preset.observeOnly"
        case .backToMissionControl: "remapping.preset.backToMissionControl"
        case .forwardToMiddleClick: "remapping.preset.forwardToMiddleClick"
        }
    }
}
