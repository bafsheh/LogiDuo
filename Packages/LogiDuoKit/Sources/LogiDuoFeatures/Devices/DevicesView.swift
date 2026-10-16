public import LogiDuoDomain
public import SwiftUI

/// The device dashboard: every known device, and the selected one's status.
public struct DevicesView: View {
    private let model: DevicesViewModel

    /// Creates the view.
    public init(model: DevicesViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.devices.isEmpty {
                EmptyStateView(
                    title: "devices.empty.title",
                    systemImage: "computermouse",
                    message: "devices.empty.message"
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.conflicts.isEmpty {
                        ConflictBanner(conflicts: model.conflicts)
                    }
                    DevicePicker(model: model)
                    Divider()
                    if let device = model.selected {
                        DeviceStatusView(device: device, model: model)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label {
                        Text("devices.refresh", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .accessibilityIdentifier("devices.refresh")
            }
        }
        .accessibilityIdentifier("devices.screen")
    }
}

/// A horizontal row of device cards.
private struct DevicePicker: View {
    let model: DevicesViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.devices) { device in
                    Button {
                        model.select(device.id)
                    } label: {
                        DeviceCard(device: device, isSelected: model.selected?.id == device.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("devices.card.\(device.category.rawValue)")
                }
            }
            .padding(16)
        }
    }
}

/// One device in the picker.
private struct DeviceCard: View {
    let device: DeviceSnapshot
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.category.systemImage)
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                HStack(spacing: 6) {
                    LinkBadge(link: device.link)
                    if let percentage = device.battery?.percentage {
                        BatteryLabel(percentage: percentage, isCharging: device.battery?.isCharging == true)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The selected device's status and features.
struct DeviceStatusView: View {
    let device: DeviceSnapshot
    let model: DevicesViewModel

    var body: some View {
        Form {
            statusSection
            if device.category == .mouse {
                DevicePointerSections(device: device, model: model)
            }
            if let keyboard = device.keyboard {
                DeviceKeyboardSections(device: device, keyboard: keyboard, model: model)
            }
            featuresSection
        }
        .formStyle(.grouped)
        .task(id: device.id) { await model.observePreferences() }
    }

    private var statusSection: some View {
        Section {
            LabeledContent {
                LinkBadge(link: device.link)
            } label: {
                Text("device.status.connection", bundle: .module)
            }
            LabeledContent {
                Text(device.transport.description)
            } label: {
                Text("device.status.transport", bundle: .module)
            }
            if let battery = device.battery {
                LabeledContent {
                    if let percentage = battery.percentage {
                        BatteryLabel(percentage: percentage, isCharging: battery.isCharging)
                    } else {
                        Text("device.status.unknown", bundle: .module)
                    }
                } label: {
                    Text("device.status.battery", bundle: .module)
                }
            }
            if let firmware = device.firmwareVersion {
                LabeledContent {
                    Text(firmware).textSelection(.enabled)
                } label: {
                    Text("device.status.firmware", bundle: .module)
                }
            }
        } header: {
            Text(device.name)
        }
    }

    private var featuresSection: some View {
        Section {
            ForEach(DeviceFeatureRow.rows(for: device.features), id: \.self) { row in
                Label {
                    Text(row.titleKey, bundle: .module)
                } icon: {
                    Image(systemName: row.systemImage).accessibilityHidden(true)
                }
            }
        } header: {
            Text("device.features.header", bundle: .module)
        }
    }
}

/// The connection state as a colored label.
struct LinkBadge: View {
    let link: DeviceLinkState

    var body: some View {
        Label {
            Text(titleKey, bundle: .module)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
        }
    }

    private var titleKey: LocalizedStringKey {
        switch link {
        case .connecting: "device.link.connecting"
        case .connected: "device.link.connected"
        case .reconnecting: "device.link.reconnecting"
        case .asleep: "device.link.asleep"
        case .unavailable: "device.link.unavailable"
        }
    }

    private var color: Color {
        switch link {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .asleep, .unavailable: .gray
        }
    }
}

/// A battery percentage with a matching symbol.
struct BatteryLabel: View {
    let percentage: Int
    let isCharging: Bool

    var body: some View {
        Label {
            Text(percentage, format: .percent.scale(1))
        } icon: {
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .accessibilityLabel(Text("device.battery.accessibility \(percentage)", bundle: .module))
    }

    private var symbol: String {
        if isCharging { return "battery.100.bolt" }
        switch percentage {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// One supported feature in the status view.
struct DeviceFeatureRow: Hashable {
    let titleKey: LocalizedStringKey
    let systemImage: String

    static func rows(for features: DeviceFeatures) -> [DeviceFeatureRow] {
        let all: [(DeviceFeatures, LocalizedStringKey, String)] = [
            (.reprogrammableControls, "device.feature.controls", "button.programmable"),
            (.adjustableResolution, "device.feature.resolution", "dial.medium"),
            (.smartShift, "device.feature.smartShift", "gearshape.2"),
            (.hiResWheel, "device.feature.hiResWheel", "scroll"),
            (.thumbwheel, "device.feature.thumbwheel", "arrow.left.and.right"),
            (.battery, "device.feature.battery", "battery.75"),
            (.backlight, "device.feature.backlight", "light.max"),
            (.fnInversion, "device.feature.fnInversion", "fn"),
            (.haptics, "device.feature.haptics", "waveform"),
        ]
        return all.filter { features.contains($0.0) }.map { DeviceFeatureRow(titleKey: $0.1, systemImage: $0.2) }
    }

    static func == (lhs: DeviceFeatureRow, rhs: DeviceFeatureRow) -> Bool { lhs.systemImage == rhs.systemImage }
    func hash(into hasher: inout Hasher) { hasher.combine(systemImage) }
}

extension DeviceCategory {
    var systemImage: String {
        switch self {
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .receiver: "dot.radiowaves.left.and.right"
        case .unclassified: "questionmark.circle"
        }
    }
}

/// Warns that other device software is running.
struct ConflictBanner: View {
    let conflicts: Set<ConflictingSoftware>

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("conflict.title \(names)", bundle: .module).font(.headline)
                Text("conflict.message", bundle: .module).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("devices.conflict")
    }

    private var names: String {
        conflicts.sorted { $0.rawValue < $1.rawValue }.map(\.displayName).formatted(.list(type: .and))
    }
}

extension ConflictingSoftware {
    var displayName: String {
        switch self {
        case .logiOptionsPlus: "Logi Options+"
        case .logitechOptions: "Logitech Options"
        case .gHub: "G HUB"
        case .mouser: "Mouser"
        }
    }
}
