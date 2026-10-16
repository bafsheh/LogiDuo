import AppKit
import LogiDuoFeatures
import SwiftUI

/// Application entry point: the main window, the menu bar extra and Settings.
@main
struct LogiDuoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(Text("app.name"), id: SceneID.main) {
            RootView(router: delegate.root.router, recovery: delegate.root.recoveryModel)
        }

        MenuBarExtra {
            MenuBarMenu(root: delegate.root)
        } label: {
            Image(systemName: "computermouse")
                .accessibilityLabel(Text("app.name"))
        }

        Settings {
            GeneralSettingsView()
        }
    }
}

/// Owns the composition root and restores native input on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let root = AppCompositionRoot()

    func applicationDidFinishLaunching(_ notification: Notification) {
        root.remapping.activate()
        Task { await root.checkRecoveryAtLaunch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        root.remapping.shutdown()
    }
}

/// Scene identifiers used with `openWindow`.
enum SceneID {
    static let main = "main"
}

/// Binds the package's menu to this app's scenes and lifecycle.
private struct MenuBarMenu: View {
    let root: AppCompositionRoot
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RemappingMenuSection(model: root.remappingModel)
            .task { await root.remappingModel.observe() }
        Divider()
        MenuBarContentView(
            router: root.router,
            openMainWindow: {
                openWindow(id: SceneID.main)
                NSApplication.shared.activate()
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }
}
