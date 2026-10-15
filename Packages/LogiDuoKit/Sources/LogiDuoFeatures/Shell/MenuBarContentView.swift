public import SwiftUI

/// Contents of the menu bar extra.
///
/// Window presentation and termination are delivered as closures so the view
/// stays free of AppKit, scene identifiers and application lifecycle concerns.
public struct MenuBarContentView: View {
    private let router: AppRouter
    private let openMainWindow: () -> Void
    private let quit: () -> Void

    /// Creates the menu.
    /// - Parameters:
    ///   - router: Receives navigation intents.
    ///   - openMainWindow: Opens (or brings forward) the main window.
    ///   - quit: Terminates the application, restoring normal input handling.
    public init(router: AppRouter, openMainWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.router = router
        self.openMainWindow = openMainWindow
        self.quit = quit
    }

    public var body: some View {
        Button {
            router.show(.devices(selected: router.selectedDevice))
            openMainWindow()
        } label: {
            Text("menu.openLogiDuo", bundle: .module)
        }
        .keyboardShortcut("o")

        Button {
            router.show(.permissions)
            openMainWindow()
        } label: {
            Text("menu.permissions", bundle: .module)
        }

        Divider()

        SettingsLink {
            Text("menu.settings", bundle: .module)
        }
        .keyboardShortcut(",")

        Divider()

        Button(action: quit) {
            Text("menu.quit", bundle: .module)
        }
        .keyboardShortcut("q")
    }
}
