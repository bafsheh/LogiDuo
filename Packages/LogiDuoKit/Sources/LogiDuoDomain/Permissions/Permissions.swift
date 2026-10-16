/// A macOS privacy permission LogiDuo may need.
public enum PermissionKind: String, CaseIterable, Hashable, Sendable, Codable {
    /// Accessibility: required to intercept and modify mouse events and to post synthetic input.
    case accessibility
    /// Input Monitoring: may be required to open some HID devices (for example keyboards).
    case inputMonitoring
}

/// What macOS reports about one permission.
public enum PermissionStatus: Hashable, Sendable, Codable {
    /// Granted.
    case granted
    /// Not granted (denied, or never granted where macOS does not distinguish).
    case denied
    /// macOS has not asked the user yet.
    case notDetermined
}

/// The observed result of opening Logitech HID interfaces (not a separate macOS permission).
public enum HIDAccessStatus: Hashable, Sendable, Codable {
    /// No interface has been opened yet.
    case untested
    /// Interfaces opened successfully.
    case available
    /// macOS refused to open an interface (usually Input Monitoring is missing).
    case refused
}

/// Something the user can switch on that needs permissions.
public enum PermissionedFeature: Hashable, Sendable {
    /// Button remapping through the event tap.
    case remapping
    /// Talking HID++ to a keyboard-class device.
    case keyboardCommunication

    /// The permissions this feature needs.
    public var requiredPermissions: [PermissionKind] {
        switch self {
        case .remapping: [.accessibility]
        case .keyboardCommunication: [.inputMonitoring]
        }
    }
}

/// What to do about a missing permission.
public enum PermissionAction: Hashable, Sendable {
    /// Nothing; the permission is granted.
    case none
    /// Show the macOS prompt (only on an explicit user request, at most once per launch).
    case prompt(PermissionKind)
    /// Explain how to grant it in System Settings; prompting again would not help.
    case instruct(PermissionKind)
}

/// Decides when LogiDuo may show a permission prompt.
///
/// Rules: never prompt on launch or in the background; prompt only when the
/// user explicitly enables a feature that needs the permission, only while
/// macOS reports it as not granted, and at most once per permission per launch.
/// After that — or when macOS already recorded a denial — LogiDuo shows
/// instructions instead. It never changes privacy settings itself.
public struct PermissionRequestPolicy: Hashable, Sendable {
    private var prompted: Set<PermissionKind> = []

    /// Creates a policy for a new launch.
    public init() {}

    /// The actions for enabling `feature`, given the current `statuses`.
    public mutating func actions(
        forEnabling feature: PermissionedFeature,
        statuses: [PermissionKind: PermissionStatus]
    ) -> [PermissionAction] {
        feature.requiredPermissions.map { kind in
            switch statuses[kind] ?? .notDetermined {
            case .granted:
                return .none
            case .denied where kind == .inputMonitoring:
                return .instruct(kind)
            case .denied, .notDetermined:
                guard prompted.insert(kind).inserted else { return .instruct(kind) }
                return .prompt(kind)
            }
        }
    }
}
