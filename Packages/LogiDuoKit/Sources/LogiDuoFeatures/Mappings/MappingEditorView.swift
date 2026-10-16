import Foundation
public import LogiDuoDomain
public import SwiftUI
import UniformTypeIdentifiers

/// The button mapping editor: pick a profile, then an action for each trigger.
public struct MappingEditorView: View {
    @Bindable private var model: MappingEditorViewModel
    @State private var capturing: TriggerItem?
    /// The trigger the application picker is for; kept apart from the presentation flag,
    /// which SwiftUI may reset before the completion handler runs.
    @State private var applicationTarget: InputTrigger?
    @State private var showsApplicationPicker = false

    /// Creates the view.
    public init(model: MappingEditorViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            profileSection
            section(.buttons, header: "mappings.section.buttons")
            gestureSection
            section(.scrolling, header: "mappings.section.scrolling")
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("mappings.screen")
        .task { await model.observe() }
        .sheet(item: $capturing) { item in
            ShortcutCaptureSheet { shortcut in
                capturing = nil
                if let shortcut { Task { await model.setAction(.customShortcut(shortcut), for: item.trigger) } }
            }
        }
        .fileImporter(
            isPresented: $showsApplicationPicker,
            allowedContentTypes: [.application],
            onCompletion: applicationChosen
        )
    }

    private var profileSection: some View {
        Section {
            Picker(selection: $model.profile) {
                Text("mappings.profile.default", bundle: .module).tag(ProfileSelection.defaultProfile)
                ForEach(model.profiles) { profile in
                    Text(profile.name.value).tag(ProfileSelection.application(profile.id))
                }
            } label: {
                Text("mappings.profile", bundle: .module)
            }
            .accessibilityIdentifier("mappings.profile")
            if let problem = model.saveProblem {
                Label {
                    Text(problem.titleKey, bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.octagon").accessibilityHidden(true)
                }
                .foregroundStyle(.red)
            }
            if let rejection = model.lastRejection {
                Label {
                    Text(rejection.titleKey, bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private var gestureSection: some View {
        Section {
            Picker(selection: $model.gestureButton) {
                ForEach(MappingEditorViewModel.gestureButtons, id: \.self) { button in
                    Text(InputTrigger.press(button).titleKey, bundle: .module).tag(button)
                }
            } label: {
                Text("mappings.gestureButton", bundle: .module)
            }
            rows(.gestures)
        } header: {
            Text("mappings.section.gestures", bundle: .module)
        } footer: {
            Text("mappings.gestures.footer", bundle: .module).foregroundStyle(.secondary)
        }
    }

    private func applicationChosen(_ result: Result<URL, any Error>) {
        guard let trigger = applicationTarget else { return }
        applicationTarget = nil
        if case .success(let url) = result,
            let identifier = Bundle(url: url)?.bundleIdentifier.flatMap(BundleIdentifier.init)
        {
            Task { await model.setAction(.openApplication(identifier), for: trigger) }
        }
    }

    private func section(_ section: MappingSection, header: LocalizedStringKey) -> some View {
        Section {
            rows(section)
        } header: {
            Text(header, bundle: .module)
        }
    }

    private func rows(_ section: MappingSection) -> some View {
        ForEach(model.rows(in: section)) { row in
            LabeledContent {
                ActionMenu(
                    row: row,
                    isApplicationProfile: model.profile != .defaultProfile,
                    choose: { action in Task { await model.setAction(action, for: row.trigger) } },
                    reset: { Task { await model.resetToInherited(row.trigger) } },
                    captureShortcut: { capturing = TriggerItem(trigger: row.trigger) },
                    chooseApplication: {
                        applicationTarget = row.trigger
                        showsApplicationPicker = true
                    }
                )
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.trigger.titleKey, bundle: .module)
                    if row.needsDeviceAccess {
                        Text("mappings.needsDeviceAccess", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    } else if row.source == .inherited {
                        Text("mappings.inherited", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("mappings.row.\(row.trigger.identifier)")
        }
    }
}

/// The action picker for one trigger.
private struct ActionMenu: View {
    let row: MappingRow
    let isApplicationProfile: Bool
    let choose: (Action) -> Void
    let reset: () -> Void
    let captureShortcut: () -> Void
    let chooseApplication: () -> Void

    var body: some View {
        Menu {
            if isApplicationProfile, row.source == .profile {
                Button {
                    reset()
                } label: {
                    Text("mappings.useDefault", bundle: .module)
                }
                Divider()
            }
            ForEach(ActionCategory.allCases, id: \.self, content: category)
            Divider()
            Button {
                captureShortcut()
            } label: {
                Text("mappings.customShortcut", bundle: .module)
            }
            Button {
                chooseApplication()
            } label: {
                Text("mappings.openApplication", bundle: .module)
            }
        } label: {
            Text(row.action.titleKey, bundle: .module)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func category(_ category: ActionCategory) -> some View {
        let choices = ActionCatalog.choices(in: category)
        if category == .native {
            ForEach(choices, content: item)
        } else {
            Menu {
                ForEach(choices, content: item)
            } label: {
                Text(category.titleKey, bundle: .module)
            }
        }
    }

    private func item(_ choice: ActionChoice) -> some View {
        Button {
            choose(choice.action)
        } label: {
            Text(choice.titleKey, bundle: .module)
        }
    }
}

extension MappingRejection {
    var titleKey: LocalizedStringKey {
        switch self {
        case .protectedTrigger: "mappings.rejected.protected"
        case .duplicateTrigger: "mappings.rejected.duplicate"
        case .selfReferential: "mappings.rejected.selfReferential"
        case .clickCycle: "mappings.rejected.cycle"
        }
    }
}

/// A trigger as a sheet item.
private struct TriggerItem: Identifiable {
    let trigger: InputTrigger
    var id: String { trigger.identifier }
}

extension InputTrigger {
    /// A stable identifier for accessibility and identity.
    var identifier: String {
        switch self {
        case .press(let button): "press.\(button.rawValue)"
        case .swipe(let button, let direction): "swipe.\(button.rawValue).\(direction.rawValue)"
        case .horizontalScroll(let direction): "hscroll.\(direction.rawValue)"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .press(let button): LocalizedStringKey.literal("trigger.press." + button.rawValue)
        case .swipe(_, let direction): LocalizedStringKey.literal("trigger.swipe." + direction.rawValue)
        case .horizontalScroll(let direction): LocalizedStringKey.literal("trigger.hscroll." + direction.rawValue)
        }
    }
}

extension ActionChoice {
    var titleKey: LocalizedStringKey { LocalizedStringKey.literal("action." + id) }
}

extension ActionCategory {
    var titleKey: LocalizedStringKey { LocalizedStringKey.literal("action.category." + rawValue) }
}

extension Action {
    var titleKey: LocalizedStringKey {
        switch self {
        case .customShortcut(let shortcut): "action.custom \(shortcut.displayString)"
        case .openApplication(let bundle): "action.open \(bundle.description)"
        case .unsupported: "action.unsupported"
        default: ActionCatalog.choice(for: self)?.titleKey ?? "action.unsupported"
        }
    }
}

extension LocalizedStringKey {
    /// A key from a computed string. (An interpolated literal would become a format key with arguments.)
    static func literal(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

extension ConfigurationSaveProblem {
    var titleKey: LocalizedStringKey {
        switch self {
        case .newerVersion: "config.problem.newerVersion"
        case .unreadable: "config.problem.unreadable"
        case .recoveredFromCorruption: "config.problem.recovered"
        case .saveFailed: "config.problem.saveFailed"
        }
    }
}
