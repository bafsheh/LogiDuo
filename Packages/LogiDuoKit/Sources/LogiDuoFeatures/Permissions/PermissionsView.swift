public import LogiDuoDomain
public import SwiftUI

/// What LogiDuo needs from macOS, live, with links to grant it.
public struct PermissionsView: View {
    private let model: PermissionsViewModel

    /// Creates the view.
    public init(model: PermissionsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionRow(kind: kind, status: model.status(of: kind), model: model)
                }
            } footer: {
                Text("permissions.footer", bundle: .module).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("permissions.screen")
        .task { await model.observe() }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus?
    let model: PermissionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(kind.titleKey, bundle: .module).font(.headline)
                } icon: {
                    Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(status == .granted ? .green : .orange)
                        .accessibilityHidden(true)
                }
                Spacer()
                Text(statusKey, bundle: .module).foregroundStyle(.secondary)
            }
            Text(kind.purposeKey, bundle: .module).font(.callout).foregroundStyle(.secondary)
            if status != .granted {
                HStack {
                    if status == .notDetermined {
                        Button {
                            Task { await model.request(kind) }
                        } label: {
                            Text("permissions.request", bundle: .module)
                        }
                    }
                    Button {
                        Task { await model.openSettings(for: kind) }
                    } label: {
                        Text("permissions.openSettings", bundle: .module)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissions.\(kind.rawValue)")
    }

    private var statusKey: LocalizedStringKey {
        switch status {
        case .granted: "permissions.status.granted"
        case .denied: "permissions.status.denied"
        case .notDetermined: "permissions.status.notDetermined"
        case nil: "permissions.status.checking"
        }
    }
}

extension PermissionKind {
    var titleKey: LocalizedStringKey {
        switch self {
        case .accessibility: "permissions.accessibility"
        case .inputMonitoring: "permissions.inputMonitoring"
        }
    }

    var purposeKey: LocalizedStringKey {
        switch self {
        case .accessibility: "permissions.accessibility.purpose"
        case .inputMonitoring: "permissions.inputMonitoring.purpose"
        }
    }
}
