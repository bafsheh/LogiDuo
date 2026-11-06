import LogiDuoDomain
public import SwiftUI

/// The view models of the main window's screens, created by the composition root.
@MainActor
public struct RootScreens {
    /// The device dashboard.
    public let devices: DevicesViewModel
    /// The mapping editor.
    public let mappings: MappingEditorViewModel
    /// Scroll preferences.
    public let scrolling: ScrollSettingsViewModel
    /// Application profiles.
    public let profiles: ProfilesViewModel
    /// Permission overview.
    public let permissions: PermissionsViewModel
    /// Device recovery.
    public let recovery: RecoveryViewModel

    /// Creates the set of screens.
    public init(
        devices: DevicesViewModel,
        mappings: MappingEditorViewModel,
        scrolling: ScrollSettingsViewModel,
        profiles: ProfilesViewModel,
        permissions: PermissionsViewModel,
        recovery: RecoveryViewModel
    ) {
        self.devices = devices
        self.mappings = mappings
        self.scrolling = scrolling
        self.profiles = profiles
        self.permissions = permissions
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
    /// Once per process — reopening the window after the first intro skips the splash.
    @State private var showsSplash = !Self.didPresentSplash

    private static var didPresentSplash = false

    /// Creates the root view.
    /// - Parameters:
    ///   - router: The navigation state shared with the menu bar.
    ///   - screens: The screens' view models.
    public init(router: AppRouter, screens: RootScreens) {
        self.router = router
        self.screens = screens
    }

    public var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView(selection: sidebarSelection)
            } detail: {
                DestinationView(destination: router.destination, screens: screens, router: router)
            }
            .frame(minWidth: 720, minHeight: 480)
            .opacity(showsSplash ? 0 : 1)

            if showsSplash {
                SplashView(isPresented: splashBinding)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsSplash)
    }

    private var splashBinding: Binding<Bool> {
        Binding(
            get: { showsSplash },
            set: { newValue in
                showsSplash = newValue
                if !newValue { Self.didPresentSplash = true }
            }
        )
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
    let router: AppRouter

    var body: some View {
        switch destination {
        case .devices:
            DevicesView(model: screens.devices)
        case .mappings:
            MappingEditorView(model: screens.mappings)
        case .scrolling:
            ScrollSettingsView(model: screens.scrolling)
        case .profiles:
            ProfilesView(model: screens.profiles) { id in
                screens.mappings.profile = .application(id)
                router.select(.mappings)
            }
        case .permissions:
            PermissionsView(model: screens.permissions)
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
