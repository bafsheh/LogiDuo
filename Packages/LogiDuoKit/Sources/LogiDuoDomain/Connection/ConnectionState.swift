/// A recoverable fault: the operation may succeed if retried.
public enum TransientFault: String, CaseIterable, Hashable, Sendable {
    /// The device did not answer in time (for example because it is asleep).
    case timeout
    /// The device or receiver was busy.
    case busy
    /// The transport reported an I/O error.
    case ioError
}

/// An unrecoverable fault: retrying automatically will not help.
public enum PermanentFault: String, CaseIterable, Hashable, Sendable {
    /// The device does not speak a supported protocol version.
    case unsupportedProtocol
    /// macOS denied access to the device.
    case accessDenied
    /// Transient failures repeated until the retry policy gave up.
    case retriesExhausted
}

/// Why a connection attempt failed.
public enum ConnectionFault: Hashable, Sendable {
    /// Worth retrying.
    case transient(TransientFault)
    /// Not worth retrying automatically.
    case permanent(PermanentFault)

    /// Whether an automatic retry may succeed.
    public var isRecoverable: Bool {
        if case .transient = self { true } else { false }
    }
}

/// Why a device is being recovered.
public enum RecoveryCause: Hashable, Sendable {
    /// A connection attempt failed with a transient fault.
    case attemptFailed(TransientFault)
    /// An established connection stopped answering (for example the device fell asleep).
    case unresponsive
    /// The Mac woke from sleep; device-side settings may have been lost.
    case hostWoke
}

/// Why a device is disconnected.
public enum DisconnectReason: Hashable, Sendable {
    /// LogiDuo closed the connection (for example on quit). The device is still present.
    case requested
    /// The device disappeared from the system.
    case removed
}

/// The lifecycle state of the connection to one device.
///
/// Only ``connected`` permits device commands. Every path back to ``connected``
/// passes through ``connecting(attempt:)``, which is where device-side settings
/// (button diversion, SmartShift, DPI) are applied — so they are re-applied
/// after every reconnect and wake. Every state with an open link leaves
/// through ``disconnecting``, giving the infrastructure the chance to restore
/// device defaults before releasing it.
public enum ConnectionState: Hashable, Sendable {
    /// Present on the system, not yet opened.
    case discovered
    /// Opening and configuring; `attempt` counts from 1.
    case connecting(attempt: Int)
    /// Ready for commands.
    case connected
    /// Restoring device defaults and closing.
    case disconnecting
    /// Closed or gone.
    case disconnected(DisconnectReason)
    /// Waiting to retry after a fault; `failedAttempts` counts consecutive failures so far.
    case recovering(cause: RecoveryCause, failedAttempts: Int)
    /// The Mac is asleep; nothing is attempted until it wakes.
    case suspended
    /// Gave up; needs a user retry, a removal, or rediscovery.
    case failed(PermanentFault)

    /// Whether commands may be sent to the device.
    public var acceptsCommands: Bool { self == .connected }

    /// Whether the device is believed to be present on the system.
    public var isDevicePresent: Bool { self != .disconnected(.removed) }
}

/// Something that happened to a device connection.
public enum ConnectionEvent: Hashable, Sendable {
    /// Open (or re-open) the connection.
    case connectRequested
    /// Opening and configuring succeeded.
    case connectSucceeded
    /// Opening or configuring failed.
    case connectFailed(ConnectionFault)
    /// An established connection stopped answering.
    case communicationLost
    /// LogiDuo wants to close the connection.
    case disconnectRequested
    /// Closing finished.
    case disconnectCompleted
    /// The device disappeared from the system.
    case deviceRemoved
    /// The device (re)appeared on the system.
    case deviceDiscovered
    /// The Mac is about to sleep.
    case hostWillSleep
    /// The Mac woke from sleep.
    case hostDidWake
}
