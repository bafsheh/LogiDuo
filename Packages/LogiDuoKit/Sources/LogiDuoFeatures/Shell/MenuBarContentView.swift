import Foundation
import LogiDuoDomain
public import SwiftUI

/// Contents of the menu bar extra.
///
/// Window presentation and termination are delivered as closures so the view
/// stays free of AppKit, scene identifiers and application lifecycle concerns.
public struct MenuBarContentView: View {
    private let router: AppRouter
    private let devices: DevicesViewModel?
    private let openMainWindow: () -> Void
    private let quit: () -> Void

    /// Creates the menu.
    /// - Parameters:
    ///   - router: Receives navigation intents.
    ///   - openMainWindow: Opens (or brings forward) the main window.
    ///   - quit: Terminates the application, restoring normal input handling.
    public init(
        router: AppRouter,
        devices: DevicesViewModel? = nil,
        openMainWindow: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.router = router
        self.devices = devices
        self.openMainWindow = openMainWindow
        self.quit = quit
    }

    public var body: some View {
        if let devices, !devices.devices.isEmpty {
            ForEach(devices.devices) { device in
                Button {
                    router.selectDevice(device.id)
                    openMainWindow()
                } label: {
                    Text(Self.summary(of: device))
                }
            }
            Divider()
        }
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

    /// "MX Master 3S — 65%" (or the connection state when there is no reading).
    static func summary(of device: DeviceSnapshot) -> String {
        guard device.link == .connected else {
            return device.name + " — " + String(localized: "device.link.unavailable", bundle: .module)
        }
        guard let percentage = device.battery?.percentage else { return device.name }
        return device.name + " — \(percentage)%" + (device.battery?.isCharging == true ? " ⚡︎" : "")
    }
}
