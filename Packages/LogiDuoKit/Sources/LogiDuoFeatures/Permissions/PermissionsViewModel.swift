public import LogiDuoDomain
public import Observation

/// Reads and requests the permissions LogiDuo needs. Implemented by the composition root.
public protocol PermissionsService: Sendable {
    /// The current statuses, then every change.
    func statuses() async -> AsyncStream<[PermissionKind: PermissionStatus]>
    /// Opens the System Settings pane where `kind` is granted.
    func openSettings(for kind: PermissionKind) async
    /// Asks macOS to show its permission prompt for `kind` (macOS shows it at most once).
    func requestAccess(for kind: PermissionKind) async
}

/// Presentation state for the permission overview.
@MainActor
@Observable
public final class PermissionsViewModel {
    /// The latest statuses.
    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    private let service: any PermissionsService

    /// Creates a view model.
    public init(service: any PermissionsService) {
        self.service = service
    }

    /// The status of `kind`, `nil` until known.
    public func status(of kind: PermissionKind) -> PermissionStatus? { statuses[kind] }

    /// Whether every permission is granted.
    public var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { statuses[$0] == .granted }
    }

    /// Opens System Settings for `kind`.
    public func openSettings(for kind: PermissionKind) async {
        await service.openSettings(for: kind)
    }

    /// Requests `kind` through the system prompt.
    public func request(_ kind: PermissionKind) async {
        await service.requestAccess(for: kind)
    }

    /// Follows status changes until the calling task is cancelled.
    public func observe() async {
        for await statuses in await service.statuses() {
            self.statuses = statuses
        }
    }
}
