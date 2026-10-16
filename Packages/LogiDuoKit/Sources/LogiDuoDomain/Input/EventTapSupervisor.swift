/// The value LogiDuo writes into every event it synthesizes (the CoreGraphics
/// event source user-data field), so the event tap can recognise and pass its
/// own output and never feed it back into the mappings.
///
/// Deliberately different from Mouser's markers, so that the two applications
/// cannot mistake each other's synthetic events for their own.
public enum SyntheticEventMarker {
    /// `'LGDO'` in ASCII.
    public static let value: Int64 = 0x4C47_444F

    /// Whether an event carrying `userData` was synthesized by LogiDuo.
    public static func isLogiDuoEvent(userData: Int64) -> Bool {
        userData == value
    }
}

/// Something that happened to the global event tap or its permission.
public enum EventTapSignal: Hashable, Sendable {
    /// Remapping should start (permission granted and mappings non-empty).
    case startRequested
    /// Remapping should stop (user toggle, quit, no mappings).
    case stopRequested
    /// The tap was installed and is receiving events.
    case tapInstalled
    /// The tap could not be installed (usually: Accessibility not granted).
    case tapInstallationFailed
    /// macOS disabled the tap because a callback took too long.
    case disabledByTimeout
    /// macOS disabled the tap because of user input (secure input fields).
    case disabledByUserInput
    /// Accessibility permission was revoked while running.
    case permissionRevoked
    /// Accessibility permission became available.
    case permissionGranted
}

/// What the system layer must do in response to a signal, in order.
public enum EventTapEffect: Hashable, Sendable {
    /// Create and enable the tap.
    case installTap
    /// Re-enable the existing tap.
    case reenableTap
    /// Remove the tap; input becomes fully native.
    case removeTap
    /// Run ``InputInterpreter/cancelAll(at:)`` and perform its releases.
    case cancelHolds
    /// Tell the user why remapping is not active.
    case notify(EventTapStopReason)
}

/// Why remapping is not active.
public enum EventTapStopReason: Hashable, Sendable {
    /// Accessibility permission is missing or was revoked.
    case permissionMissing
    /// macOS kept disabling the tap; LogiDuo stopped remapping to keep input usable.
    case repeatedTimeouts
}

/// Supervision state of the event tap.
public enum EventTapState: Hashable, Sendable {
    /// No tap; input is native.
    case inactive
    /// Waiting for the tap to be installed.
    case installing
    /// Intercepting events.
    case active
    /// Not intercepting because of `reason`; input is native.
    case suspended(EventTapStopReason)
}

/// The recovery policy for the global event tap, as a pure state machine.
///
/// Rules:
/// * Every path that stops interception cancels held presses *before* the tap
///   goes away, so no synthetic button or key stays down.
/// * A tap disabled by timeout or user input is re-enabled immediately. If it
///   is disabled by timeout ``maximumTimeouts`` times within ``timeoutWindow``,
///   remapping is suspended (fail-safe to native input) and the user is told.
/// * Losing Accessibility permission removes the tap; it is re-installed only
///   when permission returns.
///
/// If LogiDuo crashes or is killed, macOS removes its event tap with the
/// process, so interception itself can never outlive the app. Device-side
/// changes (button diversion) are different: see ``RestorationJournal``.
public struct EventTapSupervisor: Hashable, Sendable {
    /// Timeouts tolerated within ``timeoutWindow`` before failing safe.
    public static let maximumTimeouts = 3
    /// The window in which timeouts are counted.
    public static let timeoutWindow = Duration.seconds(10)

    /// The current state.
    public private(set) var state: EventTapState = .inactive
    private var recentTimeouts: [Duration] = []

    /// Creates an inactive supervisor.
    public init() {}

    /// Applies `signal` received at monotonic `time` and returns the effects to perform.
    public mutating func handle(_ signal: EventTapSignal, at time: Duration) -> [EventTapEffect] {
        switch (state, signal) {
        case (.inactive, .startRequested), (.suspended(.permissionMissing), .permissionGranted):
            state = .installing
            return [.installTap]
        case (.suspended(.repeatedTimeouts), .startRequested):
            recentTimeouts = []
            state = .installing
            return [.installTap]
        case (.installing, .tapInstalled):
            state = .active
            return []
        case (.installing, .tapInstallationFailed), (.installing, .permissionRevoked):
            state = .suspended(.permissionMissing)
            return [.notify(.permissionMissing)]
        case (.active, .disabledByUserInput):
            return [.cancelHolds, .reenableTap]
        case (.active, .disabledByTimeout):
            return timedOut(at: time)
        case (.active, .permissionRevoked):
            state = .suspended(.permissionMissing)
            return [.cancelHolds, .removeTap, .notify(.permissionMissing)]
        case (.active, .stopRequested), (.installing, .stopRequested):
            state = .inactive
            return [.cancelHolds, .removeTap]
        case (.suspended, .stopRequested):
            state = .inactive
            return []
        default:
            return []
        }
    }

    private mutating func timedOut(at time: Duration) -> [EventTapEffect] {
        recentTimeouts = recentTimeouts.filter { time - $0 < Self.timeoutWindow } + [time]
        guard recentTimeouts.count >= Self.maximumTimeouts else { return [.cancelHolds, .reenableTap] }
        state = .suspended(.repeatedTimeouts)
        return [.cancelHolds, .removeTap, .notify(.repeatedTimeouts)]
    }
}
