import Foundation
public import SwiftUI

/// The application's Settings window.
public struct GeneralSettingsView: View {
    private let model: AppSettingsViewModel
    private let importModel: MouserImportViewModel?
    @State private var importing = false

    /// Creates the settings view.
    public init(model: AppSettingsViewModel, importModel: MouserImportViewModel? = nil) {
        self.model = model
        self.importModel = importModel
    }

    public var body: some View {
        Form {
            startupSection
            if importModel != nil {
                Section {
                    Button {
                        importing = true
                    } label: {
                        Text("settings.importMouser", bundle: .module)
                    }
                    .accessibilityIdentifier("settings.importMouser")
                }
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
        .sheet(isPresented: $importing) {
            if let importModel {
                MouserImportView(model: importModel) { importing = false }
            }
        }
    }

    private var startupSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: setLaunchAtLogin)) {
                Text("settings.launchAtLogin", bundle: .module)
            }
            .accessibilityIdentifier("settings.launchAtLogin")
            if model.loginItemNeedsApproval {
                Text("settings.launchAtLogin.approval", bundle: .module).font(.caption).foregroundStyle(.orange)
            }
            Toggle(isOn: Binding(get: { model.showsWindowAtLaunch }, set: setShowsWindow)) {
                Text("settings.showWindowAtLaunch", bundle: .module)
            }
        } footer: {
            Text("settings.menuBar.footer", bundle: .module).foregroundStyle(.secondary)
        }
    }

    private func setLaunchAtLogin(_ value: Bool) {
        Task { await model.setLaunchAtLogin(value) }
    }

    private func setShowsWindow(_ value: Bool) {
        Task { await model.setShowsWindowAtLaunch(value) }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}
