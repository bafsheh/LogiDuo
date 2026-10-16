public import LogiDuoDomain
public import Observation

/// Owns main-window navigation state and translates navigation intents into it.
///
/// All mutations happen on the main actor because SwiftUI observes this state
/// directly. The router knows nothing about devices beyond their identifiers
/// and nothing about windows, so it can be exercised without hardware, AppKit
/// or infrastructure. Bringing the window forward is the scene layer's job.
@MainActor
@Observable
public final class AppRouter {
    /// The selected sidebar entry.
    public private(set) var destination: SidebarDestination
    /// The device shown in the detail column while ``destination`` is `.devices`.
    public private(set) var selectedDevice: DeviceID?
    /// Creates a router positioned at `initialRoute`.
    public init(initialRoute: AppRoute = .devices(selected: nil)) {
        destination = initialRoute.destination
        selectedDevice = nil
        apply(initialRoute)
    }

    /// The route currently displayed.
    public var currentRoute: AppRoute {
        switch destination {
        case .devices: .devices(selected: selectedDevice)
        case .mappings: .mappings
        case .scrolling: .scrolling
        case .profiles: .profiles
        case .permissions: .permissions
        case .recovery: .recovery
        }
    }

    /// Navigates to `route` inside the main window.
    public func show(_ route: AppRoute) {
        apply(route)
    }

    /// Changes the sidebar selection, keeping the device selection for when the
    /// user returns to the device list.
    public func select(_ destination: SidebarDestination) {
        self.destination = destination
    }

    /// Selects a device in the device list.
    public func selectDevice(_ device: DeviceID?) {
        destination = .devices
        selectedDevice = device
    }

    /// Clears the device selection if it refers to a device that is no longer known.
    ///
    /// - Parameter knownDevices: Identifiers of every device the app currently tracks.
    public func reconcile(knownDevices: Set<DeviceID>) {
        if let selectedDevice, !knownDevices.contains(selectedDevice) {
            self.selectedDevice = nil
        }
    }

    private func apply(_ route: AppRoute) {
        destination = route.destination
        if case .devices(let selected) = route {
            selectedDevice = selected
        }
    }
}
