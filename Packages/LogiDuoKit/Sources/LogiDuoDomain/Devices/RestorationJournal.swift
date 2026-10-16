/// A device-side setting LogiDuo may change and must be able to undo.
public enum RestorableSetting: Hashable, Sendable, Codable {
    /// Diversion of a button to LogiDuo (undone by un-diverting).
    case buttonDiversion(MouseButton)
    /// The high-resolution wheel mode byte.
    case wheelMode
    /// The thumbwheel reporting mode.
    case thumbwheelMode
    /// SmartShift mode and threshold.
    case smartShift
    /// Pointer resolution.
    case resolution
}

/// The value to restore, captured before the change.
public enum RestorationValue: Hashable, Sendable, Codable {
    /// Not diverted (the device default for every button).
    case notDiverted
    /// A raw register or mode byte.
    case byte(UInt8)
    /// Several raw bytes (for example SmartShift mode and threshold).
    case bytes([UInt8])
    /// A resolution in dots per inch.
    case resolution(Int)
}

/// One pending restoration.
public struct RestorationEntry: Hashable, Sendable, Codable {
    /// The device the change applies to.
    public let device: DeviceID
    /// The changed setting.
    public let setting: RestorableSetting
    /// The value from before LogiDuo's first change.
    public let original: RestorationValue
}

/// Records device-side changes that must be undone, so they can be restored
/// even after LogiDuo crashes or is killed.
///
/// Protocol (enforced by the device layer and persisted atomically):
/// 1. ``willApply(_:on:original:)`` is recorded and **persisted before** the
///    change is sent to the device.
/// 2. ``restored(_:on:)`` is recorded only after the device confirmed the restore.
/// 3. At launch, a non-empty journal means the previous run ended without
///    restoring; those devices are restored as soon as they reconnect, before
///    any new configuration is applied.
///
/// The first recorded original is kept: if LogiDuo crashes repeatedly, the
/// journal still holds the device's true pre-LogiDuo value, not a value
/// LogiDuo itself set. Process-exit handlers cannot protect against crashes
/// or force-quit; this journal is the recovery path for those cases. Until it
/// runs, the user can also restore defaults by power-cycling the device
/// (temporary HID++ settings are not stored in firmware — to be verified per
/// device before relying on it).
public struct RestorationJournal: Hashable, Sendable, Codable {
    private struct Key: Hashable, Sendable, Codable {
        let device: DeviceID
        let setting: RestorableSetting
    }

    private var entries: [Key: RestorationValue] = [:]

    /// Creates an empty journal.
    public init() {}

    /// Whether no restoration is pending.
    public var isClean: Bool { entries.isEmpty }

    /// Records a change that is about to be applied. Keeps an already recorded original.
    public mutating func willApply(_ setting: RestorableSetting, on device: DeviceID, original: RestorationValue) {
        let key = Key(device: device, setting: setting)
        if entries[key] == nil {
            entries[key] = original
        }
    }

    /// Records that `setting` was restored on `device`.
    public mutating func restored(_ setting: RestorableSetting, on device: DeviceID) {
        entries[Key(device: device, setting: setting)] = nil
    }

    /// Pending restorations for `device`, in a stable order (diversions first).
    public func pending(for device: DeviceID) -> [RestorationEntry] {
        entries
            .filter { $0.key.device == device }
            .map { RestorationEntry(device: $0.key.device, setting: $0.key.setting, original: $0.value) }
            .sorted { Self.order($0.setting) < Self.order($1.setting) }
    }

    /// Devices with pending restorations.
    public var devicesNeedingRestoration: Set<DeviceID> { Set(entries.keys.map(\.device)) }

    private static func order(_ setting: RestorableSetting) -> String {
        switch setting {
        case .buttonDiversion(let button): "0.\(button.rawValue)"
        case .wheelMode: "1"
        case .thumbwheelMode: "2"
        case .smartShift: "3"
        case .resolution: "4"
        }
    }
}
