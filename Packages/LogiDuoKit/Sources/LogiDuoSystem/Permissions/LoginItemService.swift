import ServiceManagement

/// Registers LogiDuo as a login item with `SMAppService` (no helper, no LaunchAgent).
public struct LoginItemService: Sendable {
    /// Creates the service.
    public init() {}

    /// Whether LogiDuo is registered to open at login.
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Whether macOS is waiting for the person to approve the login item in System Settings.
    public var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Registers or unregisters; returns the resulting state.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // The state below reflects what macOS actually did (for example, approval pending).
        }
        return isEnabled
    }
}
