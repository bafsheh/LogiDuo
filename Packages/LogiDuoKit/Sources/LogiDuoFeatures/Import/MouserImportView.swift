import Foundation
public import LogiDuoDomain
public import SwiftUI
import UniformTypeIdentifiers

/// Previews a Mouser configuration and imports it on confirmation.
public struct MouserImportView: View {
    private let model: MouserImportViewModel
    private let done: () -> Void
    @State private var choosingFile = false

    /// Creates the view; `done` closes it.
    public init(model: MouserImportViewModel, done: @escaping () -> Void) {
        self.model = model
        self.done = done
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("import.title", bundle: .module).font(.title2.bold())
            content
            buttons
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task { if model.phase == .idle { await model.loadDefault() } }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await model.load(url) } }
        }
        .accessibilityIdentifier("import.sheet")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            Label {
                Text(failure.titleKey, bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .preview(let preview):
            MouserImportPreviewList(preview: preview)
        case .imported:
            Label {
                Text("import.done", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var buttons: some View {
        HStack {
            Button {
                choosingFile = true
            } label: {
                Text("import.chooseFile", bundle: .module)
            }
            if model.canUndo {
                Button {
                    Task { await model.undo() }
                } label: {
                    Text("import.undo", bundle: .module)
                }
                .accessibilityIdentifier("import.undo")
            }
            Spacer()
            Button(role: .cancel) {
                model.cancel()
                done()
            } label: {
                Text(model.phase == .imported ? "import.close" : "import.cancel", bundle: .module)
            }
            .keyboardShortcut(.cancelAction)
            if model.preview != nil {
                Button {
                    Task { await model.confirm() }
                } label: {
                    Text("import.confirm", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("import.confirm")
            }
        }
    }
}

/// What the import will change.
private struct MouserImportPreviewList: View {
    let preview: MouserImportPreview

    var body: some View {
        List {
            Section {
                Text("import.preview.explanation \(preview.sourceVersion)", bundle: .module).font(.callout)
            }
            mappingsSection
            if !preview.profiles.isEmpty { profilesSection }
            settingsSection
            if !preview.notes.isEmpty { notesSection }
        }
    }

    private var mappingsSection: some View {
        Section {
            if preview.defaultMappings.isEmpty {
                Text("import.preview.noMappings", bundle: .module).foregroundStyle(.secondary)
            }
            ForEach(preview.defaultMappings, id: \.self) { mapping in
                LabeledContent {
                    Text(mapping.action.titleKey, bundle: .module)
                } label: {
                    Text(mapping.trigger.titleKey, bundle: .module)
                }
            }
        } header: {
            Text("import.preview.mappings", bundle: .module)
        }
    }

    private var profilesSection: some View {
        Section {
            ForEach(preview.profiles) { profile in
                Text("import.preview.profile \(profile.name.value) \(profile.mappings.count)", bundle: .module)
            }
        } header: {
            Text("import.preview.profiles", bundle: .module)
        }
    }

    private var notesSection: some View {
        Section {
            ForEach(preview.notes, id: \.self) { note in
                Text(note.text).font(.callout)
            }
        } header: {
            Text("import.preview.notes", bundle: .module)
        }
    }

    private var settingsSection: some View {
        Section {
            if let dpi = preview.pointer.resolution {
                LabeledContent {
                    Text("\(dpi) DPI")
                } label: {
                    Text("pointer.resolution", bundle: .module)
                }
            }
            LabeledContent {
                Text(preview.scroll.invertVertical ? "import.yes" : "import.no", bundle: .module)
            } label: {
                Text("scroll.invertVertical", bundle: .module)
            }
            LabeledContent {
                Text(preview.scroll.invertHorizontal ? "import.yes" : "import.no", bundle: .module)
            } label: {
                Text("scroll.invertHorizontal", bundle: .module)
            }
            Text("import.preview.keeps", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("import.preview.settings", bundle: .module)
        }
    }
}

extension MouserImportFailure {
    var titleKey: LocalizedStringKey {
        switch self {
        case .fileNotFound: "import.failure.notFound"
        case .unreadable: "import.failure.unreadable"
        case .invalid(.newerVersion(let version)): "import.failure.newer \(version)"
        case .invalid: "import.failure.invalid"
        case .backupFailed: "import.failure.backup"
        }
    }
}

extension MouserImportNote {
    /// A short English description (notes name Mouser's own identifiers).
    var text: String {
        switch self {
        case .unsupportedAction(let button, let action): "“\(button)”: action “\(action)” is not available in LogiDuo."
        case .unsupportedButton(let button): "“\(button)” is not supported yet (Actions Ring)."
        case .conflictingMapping(let button): "\(button): left out because it conflicts with another mapping."
        case .unknownApplication(let profile, let application):
            "\(profile): “\(application)” is not installed or not recognised."
        case .skippedProfile(let profile): "Profile “\(profile)” was left out: none of its applications were found."
        case .startAtLoginNotImported: "Mouser opened at login. LogiDuo's own setting is unchanged; set it in Settings."
        }
    }
}
