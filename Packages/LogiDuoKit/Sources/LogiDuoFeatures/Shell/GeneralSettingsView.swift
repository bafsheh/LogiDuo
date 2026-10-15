public import SwiftUI

/// The application's Settings window.
public struct GeneralSettingsView: View {
    /// Creates the settings view.
    public init() {}

    public var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(Self.versionString)
                } label: {
                    Text("settings.version", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}
