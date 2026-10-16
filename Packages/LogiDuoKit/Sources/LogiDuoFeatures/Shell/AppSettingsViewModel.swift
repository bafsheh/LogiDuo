public import LogiDuoDomain
public import Observation

/// Starting LogiDuo at login. Implemented by the composition root (SMAppService).
public protocol LoginItemControlling: Sendable {
    /// Whether LogiDuo starts at login.
    func isEnabled() async -> Bool
    /// Turns starting at login on or off; returns the resulting state.
    func setEnabled(_ enabled: Bool) async -> Bool
}

/// Presentation state for the Settings window.
@MainActor
@Observable
public final class AppSettingsViewModel {
    /// Whether LogiDuo starts at login (mirrors the system's login items).
    public private(set) var launchAtLogin = false
    /// Whether the main window opens at launch.
    public private(set) var showsWindowAtLaunch = true

    private let loginItem: any LoginItemControlling
    private let repository: any ConfigurationRepositing

    /// Creates a view model.
    public init(loginItem: any LoginItemControlling, repository: any ConfigurationRepositing) {
        self.loginItem = loginItem
        self.repository = repository
    }

    /// Turns starting at login on or off.
    public func setLaunchAtLogin(_ enabled: Bool) async {
        launchAtLogin = await loginItem.setEnabled(enabled)
    }

    /// Sets whether the main window opens at launch.
    public func setShowsWindowAtLaunch(_ shows: Bool) async {
        showsWindowAtLaunch = shows
        await repository.update { $0.general.showsWindowAtLaunch = shows }
    }

    /// Loads the current values.
    public func load() async {
        launchAtLogin = await loginItem.isEnabled()
        showsWindowAtLaunch = await repository.current().general.showsWindowAtLaunch
    }
}
