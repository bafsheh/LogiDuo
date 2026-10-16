import ApplicationServices
public import Foundation
import IOKit.hid
public import LogiDuoDomain

/// Reads and requests macOS privacy permissions. Abstracted for tests.
public protocol PermissionChecking: Sendable {
    /// The current status of `kind`. Never prompts.
    func status(of kind: PermissionKind) -> PermissionStatus
    /// Shows the macOS prompt for `kind` (macOS itself shows it at most once per app).
    func requestPrompt(for kind: PermissionKind)
}

/// The real permission checks, using documented APIs only.
///
/// * Accessibility: `AXIsProcessTrusted()`; the prompt is
///   `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt`.
///   macOS does not distinguish "never asked" from "denied", so a missing grant is `.denied`.
/// * Input Monitoring: `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`; the
///   prompt is `IOHIDRequestAccess`.
///
/// Nothing here modifies privacy settings; granting always requires the user.
public struct SystemPermissionChecker: PermissionChecking {
    /// Creates a checker.
    public init() {}

    /// The current status of `kind`.
    public func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined
            }
        }
    }

    /// Shows the macOS prompt for `kind`.
    public func requestPrompt(for kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }
}

/// Where the user grants each permission.
public enum PermissionSettingsLink {
    /// The System Settings pane for `kind`.
    public static func url(for kind: PermissionKind) -> URL? {
        let anchor =
            switch kind {
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Plain-language instructions for granting `kind`.
    public static func instructions(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            "Open System Settings › Privacy & Security › Accessibility and turn on LogiDuo."
        case .inputMonitoring:
            "Open System Settings › Privacy & Security › Input Monitoring and turn on LogiDuo."
        }
    }
}

/// Watches permission status and reports changes.
///
/// macOS offers no change notification for Accessibility, so status is polled
/// on an injected clock (every two seconds by default, as in Mouser). Polling
/// only reads status; it never prompts.
public final class PermissionMonitor<MonitorClock: Clock>: Sendable where MonitorClock.Duration == Duration {
    /// Status snapshots whenever any permission changes, starting with the initial one.
    public let changes: AsyncStream<[PermissionKind: PermissionStatus]>

    private let checker: any PermissionChecking
    private let clock: MonitorClock
    private let interval: Duration
    private let sink: AsyncStream<[PermissionKind: PermissionStatus]>.Continuation

    /// Creates a monitor. Call ``run()`` to start polling.
    public init(checker: any PermissionChecking, clock: MonitorClock, interval: Duration = .seconds(2)) {
        self.checker = checker
        self.clock = clock
        self.interval = interval
        (changes, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// The current status of every permission.
    public func snapshot() -> [PermissionKind: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, checker.status(of: $0)) })
    }

    /// Polls until the calling task is cancelled, publishing each change.
    public func run() async {
        var last = snapshot()
        sink.yield(last)
        var deadline = clock.now.advanced(by: interval)
        while !Task.isCancelled {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                break
            }
            deadline = deadline.advanced(by: interval)
            let current = snapshot()
            if current != last {
                last = current
                sink.yield(current)
            }
        }
        sink.finish()
    }
}
