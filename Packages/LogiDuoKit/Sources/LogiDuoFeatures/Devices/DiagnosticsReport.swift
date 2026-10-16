import Foundation
public import LogiDuoDomain

/// A plain-text description of the attached devices for support requests.
///
/// Privacy: contains names, models, firmware, transports and capabilities only —
/// never unit identifiers, serial numbers or LogiDuo's device keys.
public enum DiagnosticsReport {
    /// The report for `devices`.
    public static func text(for devices: [DeviceSnapshot], appVersion: String, systemVersion: String) -> String {
        var lines = ["LogiDuo \(appVersion) on macOS \(systemVersion)", ""]
        if devices.isEmpty { lines.append("No devices.") }
        for device in devices {
            lines.append("\(device.name) (\(device.category.rawValue))")
            lines.append("  connection: \(device.link), \(device.transport)")
            if let model = device.model { lines.append("  model: \(model)") }
            if let firmware = device.firmwareVersion { lines.append("  firmware: \(firmware)") }
            if let battery = device.battery {
                let level = battery.percentage.map { "\($0)%" } ?? "unknown"
                lines.append("  battery: \(level)\(battery.isCharging ? ", charging" : "")")
            }
            if let resolution = device.resolution {
                let range = resolution.range
                lines.append(
                    "  resolution: \(resolution.current) DPI (\(range.minimum)–\(range.maximum), step \(range.step))"
                )
            }
            if let smartShift = device.smartShift { lines.append("  wheel: \(smartShift)") }
            if let keyboard = device.keyboard {
                lines.append("  function keys: \(keyboard.functionKeys.map { "\($0)" } ?? "unknown")")
            }
            lines.append("  features: 0x" + String(device.features.rawValue, radix: 16))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The report for `devices` with this app's and system's versions.
    public static func current(for devices: [DeviceSnapshot]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return text(for: devices, appVersion: version, systemVersion: system)
    }
}
