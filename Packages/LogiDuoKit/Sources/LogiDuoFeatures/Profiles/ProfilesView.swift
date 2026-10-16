import Foundation
public import LogiDuoDomain
public import SwiftUI
import UniformTypeIdentifiers

/// Application profiles: which apps get their own mappings, in priority order.
public struct ProfilesView: View {
    @Bindable private var model: ProfilesViewModel
    private let editMappings: (ProfileID) -> Void
    @State private var choosingApplication = false

    /// Creates the view.
    /// - Parameter editMappings: Opens the mapping editor on a profile.
    public init(model: ProfilesViewModel, editMappings: @escaping (ProfileID) -> Void) {
        self.model = model
        self.editMappings = editMappings
    }

    public var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 240)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("profiles.screen")
        .task { await model.observe() }
        .fileImporter(isPresented: $choosingApplication, allowedContentTypes: [.application]) { result in
            guard case .success(let url) = result, let bundle = Bundle(url: url),
                let identifier = bundle.bundleIdentifier.flatMap(BundleIdentifier.init)
            else { return }
            let name =
                (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            Task { await model.add(application: identifier, name: name) }
        }
        .confirmationDialog(
            Text("profiles.delete.title", bundle: .module),
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.cancelDeletion() } }),
            presenting: model.pendingDeletion
        ) { _ in
            Button(role: .destructive) {
                // Captured now: dismissing the dialog clears the pending deletion before a Task runs.
                let profile = model.pendingDeletion
                Task { await model.delete(profile) }
            } label: {
                Text("profiles.delete.confirm", bundle: .module)
            }
            Button(role: .cancel) {
                model.cancelDeletion()
            } label: {
                Text("profiles.delete.cancel", bundle: .module)
            }
        } message: { profile in
            Text("profiles.delete.message \(profile.name.value)", bundle: .module)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.profiles) { profile in
                    Label {
                        Text(profile.name.value)
                    } icon: {
                        Image(systemName: profile.isEnabled ? "app" : "app.dashed").accessibilityHidden(true)
                    }
                    .foregroundStyle(profile.isEnabled ? .primary : .secondary)
                    .tag(profile.id)
                }
            }
            Divider()
            HStack {
                Button {
                    choosingApplication = true
                } label: {
                    Label {
                        Text("profiles.add", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .accessibilityIdentifier("profiles.add")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder private var detail: some View {
        if let profile = model.selected {
            ProfileDetailView(profile: profile, model: model, editMappings: editMappings)
                .id(profile.id)
        } else {
            EmptyStateView(
                title: "profiles.empty.title",
                systemImage: "person.crop.rectangle.stack",
                message: "profiles.empty.message"
            )
        }
    }
}

/// One profile's settings.
private struct ProfileDetailView: View {
    let profile: StoredProfile
    let model: ProfilesViewModel
    let editMappings: (ProfileID) -> Void
    @State private var name = ""

    var body: some View {
        Form {
            settings
            applications
            actions
        }
        .formStyle(.grouped)
        .onAppear { name = profile.name.value }
    }

    private var settings: some View {
        Section {
            TextField(text: $name) { Text("profiles.name", bundle: .module) }
                .onSubmit { Task { await model.rename(profile.id, to: name) } }
                .onDisappear { saveName() }
            Toggle(isOn: Binding(get: { profile.isEnabled }, set: setEnabled)) {
                Text("profiles.enabled", bundle: .module)
            }
        }
    }

    private var applications: some View {
        Section {
            ForEach(profile.matchers, id: \.self) { matcher in
                Text(matcher.displayName).textSelection(.enabled)
            }
        } header: {
            Text("profiles.applications", bundle: .module)
        }
    }

    private var actions: some View {
        Section {
            Button {
                editMappings(profile.id)
            } label: {
                Text("profiles.editMappings", bundle: .module)
            }
            HStack {
                Button {
                    Task { await model.move(profile.id, up: true) }
                } label: {
                    Text("profiles.moveUp", bundle: .module)
                }
                Button {
                    Task { await model.move(profile.id, up: false) }
                } label: {
                    Text("profiles.moveDown", bundle: .module)
                }
            }
            Button(role: .destructive) {
                model.requestDeletion(profile.id)
            } label: {
                Text("profiles.delete", bundle: .module)
            }
        } footer: {
            Text("profiles.priority.footer", bundle: .module).foregroundStyle(.secondary)
        }
    }

    /// Saves a typed name even if Return was not pressed (selection change, leaving the screen).
    private func saveName() {
        guard name != profile.name.value else { return }
        let id = profile.id
        let typed = name
        Task { await model.rename(id, to: typed) }
    }

    private func setEnabled(_ enabled: Bool) {
        Task { await model.setEnabled(profile.id, enabled) }
    }
}

extension ApplicationMatcher {
    var displayName: String {
        switch self {
        case .bundleIdentifier(let bundle): bundle.description
        case .executablePath(let path): path.description
        }
    }
}
