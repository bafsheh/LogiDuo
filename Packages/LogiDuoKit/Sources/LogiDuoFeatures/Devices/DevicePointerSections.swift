import LogiDuoDomain
import SwiftUI

/// Pointer resolution and scroll wheel mode of a mouse.
struct DevicePointerSections: View {
    let device: DeviceSnapshot
    let model: DevicesViewModel
    @State private var draftResolution: Double?
    @State private var newPreset = ""

    var body: some View {
        if let resolution = device.resolution {
            resolutionSection(resolution)
            presetsSection(resolution.range)
        }
        if device.features.contains(.smartShift) {
            smartShiftSection
        }
    }

    private var preference: DeviceSettings { model.preference(for: device.id) }

    private func resolutionSection(_ resolution: ResolutionState) -> some View {
        Section {
            LabeledContent {
                Text("\(Int(draftResolution ?? Double(preference.resolution ?? resolution.current))) DPI")
                    .monospacedDigit()
            } label: {
                Text("pointer.resolution", bundle: .module)
            }
            Slider(
                value: Binding(
                    get: { draftResolution ?? Double(preference.resolution ?? resolution.current) },
                    // Snapped while dragging; no `step:` so macOS draws no tick for every value.
                    set: { draftResolution = Double(resolution.range.nearestSupported(to: Int($0.rounded()))) }
                ),
                in: Double(resolution.range.minimum)...Double(resolution.range.maximum)
            ) { editing in
                guard !editing, let value = draftResolution else { return }
                draftResolution = nil
                Task { await model.setResolution(Int(value), for: device.id) }
            }
            .accessibilityLabel(Text("pointer.resolution", bundle: .module))
            if preference.resolution != nil, preference.resolution != resolution.current {
                Text("pointer.deviceReports \(resolution.current)", bundle: .module).font(.caption).foregroundStyle(
                    .secondary
                )
            }
        } header: {
            Text("pointer.section", bundle: .module)
        } footer: {
            WriteStatusFooter(writesEnabled: model.writesEnabled, result: model.lastResult[device.id])
        }
    }

    private func presetsSection(_ range: ResolutionRange) -> some View {
        Section {
            ForEach(preference.resolutionPresets, id: \.self) { dpi in
                LabeledContent {
                    Button(role: .destructive) {
                        Task { await model.removePreset(dpi, for: device.id) }
                    } label: {
                        Image(systemName: "minus.circle").accessibilityLabel(
                            Text("pointer.presets.remove", bundle: .module)
                        )
                    }
                    .buttonStyle(.borderless)
                } label: {
                    Text("\(dpi) DPI").monospacedDigit()
                }
            }
            HStack {
                TextField(text: $newPreset) { Text("pointer.presets.new", bundle: .module) }
                    .onSubmit { addPreset(range) }
                Button {
                    addPreset(range)
                } label: {
                    Text("pointer.presets.add", bundle: .module)
                }
                .disabled(Int(newPreset) == nil)
            }
        } header: {
            Text("pointer.presets", bundle: .module)
        } footer: {
            Text("pointer.presets.footer", bundle: .module).foregroundStyle(.secondary)
        }
    }

    private func addPreset(_ range: ResolutionRange) {
        guard let value = Int(newPreset) else { return }
        newPreset = ""
        Task { await model.addPreset(range.nearestSupported(to: value), for: device.id) }
    }

    private var smartShiftSection: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { SmartShiftChoice(preference.smartShift ?? device.smartShift) },
                    set: chooseSmartShift
                )
            ) {
                ForEach(SmartShiftChoice.allCases, id: \.self) { choice in
                    Text(choice.titleKey, bundle: .module).tag(choice)
                }
            } label: {
                Text("wheel.mode", bundle: .module)
            }
            if case .automatic(let sensitivity) = preference.smartShift ?? device.smartShift {
                Stepper(
                    value: Binding(
                        get: { sensitivity },
                        set: { value in
                            Task { await model.setSmartShift(.automatic(sensitivity: value), for: device.id) }
                        }
                    ),
                    in: 1...50
                ) {
                    Text("wheel.sensitivity \(sensitivity)", bundle: .module)
                }
            }
        } header: {
            Text("wheel.section", bundle: .module)
        } footer: {
            WriteStatusFooter(writesEnabled: model.writesEnabled, result: model.lastResult[device.id])
        }
    }

    private func chooseSmartShift(_ choice: SmartShiftChoice) {
        let mode: SmartShiftMode =
            switch choice {
            case .ratchet: .ratchet
            case .freeSpin: .freeSpin
            case .automatic: .automatic(sensitivity: 10)
            }
        Task { await model.setSmartShift(mode, for: device.id) }
    }
}

/// The wheel mode without its parameter, for the picker.
enum SmartShiftChoice: CaseIterable, Hashable {
    case automatic
    case ratchet
    case freeSpin

    init(_ mode: SmartShiftMode?) {
        switch mode {
        case .freeSpin: self = .freeSpin
        case .ratchet: self = .ratchet
        case .automatic, nil: self = .automatic
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .automatic: "wheel.mode.automatic"
        case .ratchet: "wheel.mode.ratchet"
        case .freeSpin: "wheel.mode.freeSpin"
        }
    }
}

/// Explains whether a setting reached the device.
struct WriteStatusFooter: View {
    let writesEnabled: Bool
    let result: DeviceSettingResult?

    var body: some View {
        Group {
            if !writesEnabled {
                Text("device.writes.disabled", bundle: .module)
            } else if let result {
                Text(result.titleKey, bundle: .module)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension DeviceSettingResult {
    var titleKey: LocalizedStringKey {
        switch self {
        case .applied: "device.write.applied"
        case .writesDisabled: "device.writes.disabled"
        case .unsupported: "device.write.unsupported"
        case .unavailable: "device.write.unavailable"
        case .failed: "device.write.failed"
        }
    }
}
