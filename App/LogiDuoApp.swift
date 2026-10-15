import AppKit
import LogiDuoFeatures
import SwiftUI

/// Application entry point: the main window, the menu bar extra and Settings.
@main
struct LogiDuoApp: App {
    @State private var root = AppCompositionRoot()

    var body: some Scene {
        Window(Text("app.name"), id: SceneID.main) {
            RootView(router: root.router)
        }

        MenuBarExtra {
            MenuBarMenu(router: root.router)
        } label: {
            Image(systemName: "computermouse")
                .accessibilityLabel(Text("app.name"))
        }

        Settings {
            GeneralSettingsView()
        }
    }
}

/// Scene identifiers used with `openWindow`.
enum SceneID {
    static let main = "main"
}

/// Binds the package's menu to this app's scenes and lifecycle.
private struct MenuBarMenu: View {
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContentView(
            router: router,
            openMainWindow: {
                openWindow(id: SceneID.main)
                NSApplication.shared.activate()
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }
}
