import AppKit
import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoHID
import LogiDuoPersistence
import SwiftUI

/// Application entry point: the main window, the menu bar extra and Settings.
@main
struct LogiDuoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(Text("app.name"), id: SceneID.main) {
            RootView(router: delegate.root.router, screens: delegate.root.screens)
                .task { await delegate.root.devicesModel.observe() }
        }

        MenuBarExtra {
            MenuBarMenu(root: delegate.root)
        } label: {
            Image(systemName: "computermouse")
                .accessibilityLabel(Text("app.name"))
        }

        Settings {
            GeneralSettingsView(model: delegate.root.settingsModel)
        }
    }
}

/// Owns the composition root and restores native input on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let root = AppCompositionRoot()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy hands over to the running one and quits.
        if let bundle = Bundle.main.bundleIdentifier,
            let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        {
            other.activate()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        followMainWindow()
        root.remapping.activate()
        root.profiles.start()
        root.startDevices()
        let root = root
        Task {
            await root.checkRecoveryAtLaunch()
            // Recovery always shows the window; otherwise honor the preference.
            if await !root.configuration.current().general.showsWindowAtLaunch, root.recoveryModel.journal == .clean {
                for window in NSApplication.shared.windows where window.identifier?.rawValue == SceneID.main {
                    window.close()
                }
            }
        }
    }

    /// Shows a Dock icon only while the main window is open; LogiDuo stays in the menu bar.
    private func followMainWindow() {
        let center = NotificationCenter.default
        Task { @MainActor in
            for await note in center.notifications(named: NSWindow.didBecomeKeyNotification) {
                guard Self.isMainWindow(note.object) else { continue }
                NSApplication.shared.setActivationPolicy(.regular)
            }
        }
        Task { @MainActor in
            for await note in center.notifications(named: NSWindow.willCloseNotification) {
                guard Self.isMainWindow(note.object) else { continue }
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    private static func isMainWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.identifier?.rawValue == SceneID.main
    }

    /// Saves pending configuration changes before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let profiles = root.profiles
        let devices = root.devices
        Task {
            await profiles.stop()
            // Restores any device diversion before closing the connections.
            await devices.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
            devices: root.devicesModel,
            openMainWindow: {
                openWindow(id: SceneID.main)
                NSApplication.shared.activate()
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }
}
