import AppKit
public import LogiDuoDomain

/// Follows the frontmost application by notification (no polling).
///
/// * Re-reads the frontmost application after the Mac wakes and when the user
///   session becomes active again, because activation notifications can be missed.
/// * Rapid switches within `settle` are coalesced into the last one.
@MainActor
public final class FrontmostApplicationObserver {
    /// The frontmost application's identity after each (settled) change, starting with the current one.
    public let identities: AsyncStream<ApplicationIdentity?>

    private let sink: AsyncStream<ApplicationIdentity?>.Continuation
    private let settle: Duration
    private var tasks: [Task<Void, Never>] = []
    private var pending: Task<Void, Never>?
    private var last: ApplicationIdentity??

    /// Creates an observer; call ``start()`` to begin.
    public init(settle: Duration = .milliseconds(120)) {
        self.settle = settle
        (identities, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts observing.
    public func start() {
        guard tasks.isEmpty else { return }
        emit(Self.currentIdentity())
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        tasks = names.map { name in
            Task { [weak self] in
                for await _ in center.notifications(named: name).map({ _ in () }) {
                    self?.schedule()
                }
            }
        }
    }

    /// Stops observing.
    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
        pending?.cancel()
        sink.finish()
    }

    private func schedule() {
        pending?.cancel()
        let settle = settle
        pending = Task { [weak self] in
            try? await ContinuousClock().sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.emit(Self.currentIdentity())
        }
    }

    private func emit(_ identity: ApplicationIdentity?) {
        guard last != .some(identity) else { return }
        last = .some(identity)
        sink.yield(identity)
    }

    /// The identity of the frontmost application, if any.
    public static func currentIdentity() -> ApplicationIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ApplicationIdentityBuilder.identity(
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path,
            executablePath: app.executableURL?.path
        ) { path in
            Bundle(path: path)?.bundleIdentifier
        }
    }
}
