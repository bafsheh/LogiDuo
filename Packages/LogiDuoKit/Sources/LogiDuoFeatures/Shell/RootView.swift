public import SwiftUI

/// The view models of the main window's screens, created by the composition root.
@MainActor
public struct RootScreens {
    /// The device dashboard.
    public let devices: DevicesViewModel
    /// Device recovery.
    public let recovery: RecoveryViewModel

    /// Creates the set of screens.
    public init(devices: DevicesViewModel, recovery: RecoveryViewModel) {
        self.devices = devices
        self.recovery = recovery
    }
}

/// The main window: a sidebar of destinations and a detail column.
///
/// The view owns no state of its own; everything is read from and written
/// through the injected ``AppRouter`` and screen models.
public struct RootView: View {
    @Bindable private var router: AppRouter
    private let screens: RootScreens

    /// Creates the root view.
    /// - Parameters:
    ///   - router: The navigation state shared with the menu bar.
    ///   - screens: The screens' view models.
    public init(router: AppRouter, screens: RootScreens) {
        self.router = router
        self.screens = screens
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: sidebarSelection)
        } detail: {
            DestinationView(destination: router.destination, screens: screens)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: { router.destination },
            set: { newValue in
                if let newValue {
                    router.select(newValue)
                }
            }
        )
    }
}

/// Detail content for a sidebar destination.
struct DestinationView: View {
    let destination: SidebarDestination
    let screens: RootScreens

    var body: some View {
        switch destination {
        case .devices:
            DevicesView(model: screens.devices)
        case .profiles:
            EmptyStateView(title: "profiles.empty.title", systemImage: "person.crop.rectangle.stack")
        case .permissions:
            EmptyStateView(title: "permissions.title", systemImage: "lock.shield")
        case .recovery:
            RecoveryView(model: screens.recovery)
        }
    }
}

/// A localized ``ContentUnavailableView`` backed by this module's string catalog.
struct EmptyStateView: View {
    let title: LocalizedStringKey
    let systemImage: String
    var message: LocalizedStringKey?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title, bundle: .module)
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        } description: {
            if let message {
                Text(message, bundle: .module)
            }
        }
    }
}
