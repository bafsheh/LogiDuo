import AppKit

/// A launched application, wrapped so tests can query it from any context.
final class RunningApp: @unchecked Sendable {  // Invariant: NSRunningApplication's queried properties are thread-safe.
    private let application: NSRunningApplication

    init(_ application: NSRunningApplication) { self.application = application }

    var processIdentifier: pid_t { application.processIdentifier }

    /// Launch completed: WindowServer lists a window (the menu-bar item) owned by the process.
    /// `NSRunningApplication`'s own flags only refresh on a main run loop, which tests do not run.
    var isFinishedLaunching: Bool {
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier }
    }

    /// The process no longer exists.
    var isTerminated: Bool { kill(processIdentifier, 0) != 0 }
    func terminate() { application.terminate() }
    func forceTerminate() { if !isTerminated { application.forceTerminate() } }
}

/// Launches applications through NSWorkspace for system tests.
enum NSWorkspaceLaunchProxy {
    static func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        return configuration
    }

    static func launch(_ url: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> RunningApp {
        RunningApp(try await NSWorkspace.shared.openApplication(at: url, configuration: configuration))
    }
}
