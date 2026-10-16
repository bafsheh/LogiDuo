public import LogiDuoDomain

/// Temporary, explicit mapping sets for live validation, until mappings can be configured.
///
/// Each is non-destructive and affects one button at a time.
public enum ValidationPreset: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// Intercept nothing; observe only.
    case observeOnly
    /// Back button opens Mission Control.
    case backToMissionControl
    /// Forward button performs a middle click.
    case forwardToMiddleClick

    /// Stable identity for SwiftUI.
    public var id: String { rawValue }

    /// The mappings of this preset.
    public var mappings: MappingSet {
        let mappings: [ButtonMapping] =
            switch self {
            case .observeOnly: []
            case .backToMissionControl: [ButtonMapping(trigger: .press(.back), action: .system(.missionControl))]
            case .forwardToMiddleClick: [ButtonMapping(trigger: .press(.forward), action: .click(.middle))]
            }
        do {
            return try MappingSet(mappings)
        } catch {
            preconditionFailure("validation presets are valid: \(error)")
        }
    }
}

/// Why remapping is not running although the user enabled it.
public enum RemappingNotice: Hashable, Sendable {
    /// Accessibility permission is missing; macOS was asked once, now the user must grant it.
    case accessibilityRequired
    /// macOS kept disabling the event tap, so remapping stopped to keep input usable.
    case stoppedAfterRepeatedTimeouts
}

/// What the remapping control shows.
public struct RemappingStatus: Hashable, Sendable {
    /// Whether the user has remapping switched on.
    public var isEnabled: Bool
    /// Whether events are actually being intercepted.
    public var isIntercepting: Bool
    /// The active validation preset.
    public var preset: ValidationPreset
    /// Why remapping is not running, if it should be.
    public var notice: RemappingNotice?

    /// Remapping off: the launch state.
    public static let off = RemappingStatus(isEnabled: false, isIntercepting: false, preset: .observeOnly, notice: nil)

    /// Creates a status.
    public init(isEnabled: Bool, isIntercepting: Bool, preset: ValidationPreset, notice: RemappingNotice?) {
        self.isEnabled = isEnabled
        self.isIntercepting = isIntercepting
        self.preset = preset
        self.notice = notice
    }
}

/// Controls live remapping. Implemented by the application's composition root.
@MainActor
public protocol RemappingService: AnyObject {
    /// The current status.
    var status: RemappingStatus { get }
    /// Every status change, including ones caused by permission or tap events.
    var statusUpdates: AsyncStream<RemappingStatus> { get }
    /// Turns remapping on or off. Off always restores native input.
    func setEnabled(_ enabled: Bool)
    /// Selects the validation preset.
    func select(_ preset: ValidationPreset)
    /// Opens the System Settings pane where the missing permission is granted.
    func openPermissionSettings()
}
