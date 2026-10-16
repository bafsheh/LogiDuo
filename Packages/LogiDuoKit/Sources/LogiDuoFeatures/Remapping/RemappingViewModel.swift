public import Observation

/// Presentation state and intents for the menu-bar remapping control.
@MainActor
@Observable
public final class RemappingViewModel {
    /// The current status.
    public private(set) var status: RemappingStatus

    private let service: any RemappingService

    /// Creates a view model reading from `service`.
    public init(service: any RemappingService) {
        self.service = service
        self.status = service.status
    }

    /// The toggle's binding target.
    public var isEnabled: Bool {
        get { status.isEnabled }
        set { setEnabled(newValue) }
    }

    /// The localization key of the status line.
    public var statusKey: String {
        switch (status.isEnabled, status.isIntercepting, status.notice) {
        case (false, _, _): "remapping.status.off"
        case (true, _, .accessibilityRequired?): "remapping.status.needsAccessibility"
        case (true, _, .stoppedAfterRepeatedTimeouts?): "remapping.status.stopped"
        case (true, true, nil): "remapping.status.on"
        case (true, false, nil): "remapping.status.starting"
        }
    }

    /// Whether to offer the button that opens System Settings.
    public var offersPermissionSettings: Bool { status.notice == .accessibilityRequired }

    /// Turns remapping on or off.
    public func setEnabled(_ enabled: Bool) {
        service.setEnabled(enabled)
        status = service.status
    }

    /// Selects a validation preset.
    public func select(_ preset: ValidationPreset) {
        service.select(preset)
        status = service.status
    }

    /// Opens the permission settings.
    public func openPermissionSettings() {
        service.openPermissionSettings()
    }

    /// Follows status changes until the calling task is cancelled.
    public func observe() async {
        for await update in service.statusUpdates {
            status = update
        }
    }
}
