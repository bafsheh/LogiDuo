public import Foundation

/// A HID++ control identifier (CID), as listed by the device's ReprogControls feature.
public struct DeviceControlID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The 16-bit control identifier.
    public let rawValue: UInt16

    /// Creates a control identifier.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Hexadecimal form, for example `0x00C3`.
    public var description: String {
        let digits = String(rawValue, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

/// An opaque, privacy-preserving key identifying a device in the restoration journal.
///
/// Derived from the device's ``DeviceID`` by the persistence layer (salted hash),
/// so the journal on disk never contains unit identifiers or serial numbers.
public struct RestorationDeviceKey: RawRepresentable, Hashable, Sendable, Codable {
    /// The opaque key.
    public let rawValue: String

    /// Creates a key.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A device-side setting LogiDuo may change and must be able to undo.
public enum RestorableSetting: Hashable, Sendable, Codable {
    /// The reporting (divert) state of one control.
    case controlReporting(DeviceControlID)
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
    /// A control's original temporary divert state.
    case controlReporting(diverted: Bool, rawXYDiverted: Bool)
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
    public let device: RestorationDeviceKey
    /// The changed setting.
    public let setting: RestorableSetting
    /// The value from before LogiDuo's first change.
    public let original: RestorationValue
    /// How many restore attempts have failed so far.
    public let failedAttempts: Int
}

/// Records device-side changes that must be undone, so they can be restored
/// even after LogiDuo crashes or is killed.
///
/// Protocol (enforced by `DeviceWriteTransaction` and persisted durably):
/// 1. ``willApply(_:on:original:)`` is recorded and **persisted before** the change
///    is sent to the device.
/// 2. ``restored(_:on:)`` is recorded only after a read-back confirmed the restore.
///    A failed attempt is counted with ``restoreFailed(_:on:)`` and the entry is kept.
/// 3. At launch, a non-empty journal means the previous run ended without
///    restoring; those devices are restored when they next connect, before any new
///    configuration. This is next-launch recovery, not immediate crash recovery.
///
/// The first recorded original is kept, so repeated crashes cannot replace the
/// device's true pre-LogiDuo value with a value LogiDuo set.
public struct RestorationJournal: Hashable, Sendable, Codable {
    private struct Key: Hashable, Sendable, Codable {
        let device: RestorationDeviceKey
        let setting: RestorableSetting
    }

    private struct Record: Hashable, Sendable, Codable {
        let original: RestorationValue
        var failedAttempts: Int
    }

    private var records: [Key: Record] = [:]

    /// Creates an empty journal.
    public init() {}

    /// Whether no restoration is pending.
    public var isClean: Bool { records.isEmpty }

    /// Every pending entry, in a stable order.
    public var entries: [RestorationEntry] {
        records.map { key, record in
            RestorationEntry(
                device: key.device,
                setting: key.setting,
                original: record.original,
                failedAttempts: record.failedAttempts
            )
        }
        .sorted { ($0.device.rawValue, Self.order($0.setting)) < ($1.device.rawValue, Self.order($1.setting)) }
    }

    /// Records a change that is about to be applied. Keeps an already recorded original.
    public mutating func willApply(
        _ setting: RestorableSetting,
        on device: RestorationDeviceKey,
        original: RestorationValue
    ) {
        let key = Key(device: device, setting: setting)
        if records[key] == nil {
            records[key] = Record(original: original, failedAttempts: 0)
        }
    }

    /// Records that `setting` was restored and verified on `device`.
    public mutating func restored(_ setting: RestorableSetting, on device: RestorationDeviceKey) {
        records[Key(device: device, setting: setting)] = nil
    }

    /// Records a failed restore attempt; the entry stays pending.
    public mutating func restoreFailed(_ setting: RestorableSetting, on device: RestorationDeviceKey) {
        records[Key(device: device, setting: setting)]?.failedAttempts += 1
    }

    /// Pending restorations for `device`, in a stable order (control reporting first).
    public func pending(for device: RestorationDeviceKey) -> [RestorationEntry] {
        entries.filter { $0.device == device }
    }

    /// Devices with pending restorations.
    public var devicesNeedingRestoration: Set<RestorationDeviceKey> { Set(records.keys.map(\.device)) }

    private static func order(_ setting: RestorableSetting) -> String {
        switch setting {
        case .controlReporting(let control): "0.\(control)"
        case .wheelMode: "1"
        case .thumbwheelMode: "2"
        case .smartShift: "3"
        case .resolution: "4"
        }
    }
}

/// Why the journal could not be loaded or saved.
public enum RestorationJournalStoreError: Error, Hashable, Sendable {
    /// The journal file was unreadable; it was moved aside (never deleted) to `quarantinedAt`.
    case corrupted(quarantinedAt: URL)
    /// The file system refused the operation.
    case fileSystem(String)
    /// A saved journal read back differently (the write was not durable).
    case notDurable
}

/// Durable storage for the restoration journal.
public protocol RestorationJournalStoring: Sendable {
    /// Loads the journal; an absent file is an empty journal.
    /// - Throws: ``RestorationJournalStoreError/corrupted(quarantinedAt:)`` after moving an unreadable file aside.
    func load() throws(RestorationJournalStoreError) -> RestorationJournal
    /// Saves the journal atomically and durably, verifying it by reading it back.
    func save(_ journal: RestorationJournal) throws(RestorationJournalStoreError)
    /// Derives the journal key for a device.
    func key(for device: DeviceID) -> RestorationDeviceKey
}
