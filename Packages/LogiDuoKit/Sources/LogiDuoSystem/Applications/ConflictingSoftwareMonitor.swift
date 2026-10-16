import AppKit
public import LogiDuoDomain

/// Reports running software that also configures Logitech devices (Options+, G HUB, Mouser).
@MainActor
public final class ConflictingSoftwareMonitor {
    /// The conflicting software running now, then after every launch or quit.
    public let running: AsyncStream<Set<ConflictingSoftware>>

    private let sink: AsyncStream<Set<ConflictingSoftware>>.Continuation
    private var tasks: [Task<Void, Never>] = []

    /// Creates a monitor; call ``start()``.
    public init() {
        (running, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts watching application launches and quits.
    public func start() {
        guard tasks.isEmpty else { return }
        sink.yield(Self.current())
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
        tasks = names.map { name in watch(center, name) }
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in center.notifications(named: name).map({ _ in () }) {
                self?.sink.yield(Self.current())
            }
        }
    }

    /// The conflicting software running now.
    public static func current() -> Set<ConflictingSoftware> {
        Set(
            NSWorkspace.shared.runningApplications.compactMap { app in
                ConflictingSoftware.classify(bundleIdentifier: app.bundleIdentifier, name: app.localizedName)
            }
        )
    }
}
