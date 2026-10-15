public import SwiftUI

/// The main window: a sidebar of destinations and a detail column.
///
/// The view owns no state of its own; everything is read from and written
/// through the injected ``AppRouter``.
public struct RootView: View {
    @Bindable private var router: AppRouter

    /// Creates the root view.
    /// - Parameter router: The navigation state shared with the menu bar.
    public init(router: AppRouter) {
        self.router = router
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: sidebarSelection)
        } detail: {
            DestinationView(destination: router.destination)
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

    var body: some View {
        switch destination {
        case .devices:
            EmptyStateView(
                title: "devices.empty.title",
                systemImage: "computermouse",
                message: "devices.empty.message"
            )
        case .profiles:
            EmptyStateView(title: "profiles.empty.title", systemImage: "person.crop.rectangle.stack")
        case .permissions:
            EmptyStateView(title: "permissions.title", systemImage: "lock.shield")
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
