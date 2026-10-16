public import LogiDuoDomain

/// Top-level destinations shown in the main window's sidebar.
public enum SidebarDestination: String, CaseIterable, Hashable, Sendable, Identifiable {
    case devices
    case profiles
    case permissions
    case recovery

    /// Stable identity for SwiftUI lists.
    public var id: String { rawValue }
}

/// A fully specified navigation target inside the main window.
///
/// Routes are plain values so that navigation intents can be produced by any
/// feature (menu bar, notifications, deep links) and tested without UI.
public enum AppRoute: Hashable, Sendable {
    /// The device list, optionally focused on one device.
    case devices(selected: DeviceID?)
    /// Application profile management.
    case profiles
    /// The permission status overview.
    case permissions
    /// Device recovery (exact restore and emergency reset).
    case recovery

    /// The sidebar entry that owns this route.
    public var destination: SidebarDestination {
        switch self {
        case .devices: .devices
        case .profiles: .profiles
        case .permissions: .permissions
        case .recovery: .recovery
        }
    }
}
