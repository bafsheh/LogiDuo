import LogiDuoDomain
import SwiftUI

/// Function keys, disabled keys and backlight of a keyboard.
struct DeviceKeyboardSections: View {
    let device: DeviceSnapshot
    let keyboard: KeyboardState
    let model: DevicesViewModel

    var body: some View {
        if let mode = keyboard.functionKeys {
            functionKeysSection(mode)
        }
        if !keyboard.disableableKeys.isEmpty {
            disableKeysSection
        }
        if let backlight = keyboard.backlight {
            Section {
                LabeledContent {
                    Text(backlight == .on ? "keyboard.backlight.on" : "keyboard.backlight.off", bundle: .module)
                } label: {
                    Text("keyboard.backlight", bundle: .module)
                }
            } footer: {
                Text("keyboard.backlight.footer", bundle: .module).foregroundStyle(.secondary)
            }
        }
    }

    private func functionKeysSection(_ mode: FunctionKeyMode) -> some View {
        Section {
            Toggle(isOn: Binding(get: { mode == .standard }, set: setStandard)) {
                Text("keyboard.functionKeys", bundle: .module)
            }
            .disabled(!model.writesEnabled)
        } header: {
            Text("keyboard.section.keys", bundle: .module)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    mode == .standard ? "keyboard.functionKeys.standard" : "keyboard.functionKeys.special",
                    bundle: .module
                )
                WriteStatusFooter(writesEnabled: model.writesEnabled, result: model.lastResult[device.id])
            }
            .foregroundStyle(.secondary)
        }
    }

    private var disableKeysSection: some View {
        Section {
            ForEach(KeyboardKeys.all.filter { keyboard.disableableKeys.contains($0) }, id: \.rawValue) { key in
                Toggle(
                    isOn: Binding(
                        get: { keyboard.disabledKeys.contains(key) },
                        set: { disabled in setKey(key, disabled) }
                    )
                ) {
                    Text(key.titleKey, bundle: .module)
                }
                .disabled(!model.writesEnabled)
            }
        } header: {
            Text("keyboard.section.disable", bundle: .module)
        }
    }

    private func setStandard(_ standard: Bool) {
        Task { await model.setFunctionKeys(standard ? .standard : .special, for: device.id) }
    }

    private func setKey(_ key: KeyboardKeys, _ disabled: Bool) {
        Task { await model.setKey(key, disabled: disabled, for: device.id) }
    }
}

extension KeyboardKeys {
    var titleKey: LocalizedStringKey {
        switch self {
        case .capsLock: "keyboard.key.capsLock"
        case .numLock: "keyboard.key.numLock"
        case .scrollLock: "keyboard.key.scrollLock"
        case .insert: "keyboard.key.insert"
        default: "keyboard.key.windows"
        }
    }
}
