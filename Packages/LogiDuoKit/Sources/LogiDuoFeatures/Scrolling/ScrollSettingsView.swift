import LogiDuoDomain
public import SwiftUI

/// Scroll direction and behavior for Logitech mice.
public struct ScrollSettingsView: View {
    private let model: ScrollSettingsViewModel

    /// Creates the view.
    public init(model: ScrollSettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                toggle("scroll.invertVertical", value: model.settings.invertVertical) { $0.invertVertical = $1 }
                toggle("scroll.invertHorizontal", value: model.settings.invertHorizontal) { $0.invertHorizontal = $1 }
            } header: {
                Text("scroll.section.direction", bundle: .module)
            } footer: {
                Text("scroll.direction.footer", bundle: .module).foregroundStyle(.secondary)
            }
            Section {
                toggle("scroll.shiftHorizontal", value: model.settings.shiftScrollsHorizontally) { settings, on in
                    settings.shiftScrollsHorizontally = on
                }
                toggle("scroll.ignoreTrackpad", value: model.settings.ignoreTrackpad) { $0.ignoreTrackpad = $1 }
            } header: {
                Text("scroll.section.behavior", bundle: .module)
            } footer: {
                Text("scroll.requiresRemapping", bundle: .module).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("scroll.screen")
        .task { await model.observe() }
    }

    private func toggle(
        _ title: LocalizedStringKey,
        value: Bool,
        set: @escaping @Sendable (inout ScrollSettings, Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { newValue in Task { await model.update { set(&$0, newValue) } } })) {
            Text(title, bundle: .module)
        }
    }
}
