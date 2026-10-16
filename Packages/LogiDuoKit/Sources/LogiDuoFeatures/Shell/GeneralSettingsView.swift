import Foundation
public import SwiftUI

/// The application's Settings window.
public struct GeneralSettingsView: View {
    private let model: AppSettingsViewModel

    /// Creates the settings view.
    public init(model: AppSettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { value in Task { await model.setLaunchAtLogin(value) } }
                    )
                ) {
                    Text("settings.launchAtLogin", bundle: .module)
                }
                .accessibilityIdentifier("settings.launchAtLogin")
                Toggle(
                    isOn: Binding(
                        get: { model.showsWindowAtLaunch },
                        set: { value in Task { await model.setShowsWindowAtLaunch(value) } }
                    )
                ) {
                    Text("settings.showWindowAtLaunch", bundle: .module)
                }
            } footer: {
                Text("settings.menuBar.footer", bundle: .module).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Text(Self.versionString)
                } label: {
                    Text("settings.version", bundle: .module)
                }
                Text("settings.about", bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.load() }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}
