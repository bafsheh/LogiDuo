/// How many consecutive transient failures are tolerated before giving up.
public struct RetryPolicy: Hashable, Sendable {
    /// The number of consecutive failed attempts after which recovery stops; at least 1.
    public let maxConsecutiveFailures: Int

    /// Creates a policy, rejecting values below 1.
    public init?(maxConsecutiveFailures: Int) {
        guard maxConsecutiveFailures >= 1 else { return nil }
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    private init(validated count: Int) {
        maxConsecutiveFailures = count
    }

    /// Eight consecutive failures before giving up (backoff grows in between).
    public static let standard = RetryPolicy(validated: 8)
}

/// An event that is not legal in the current state.
public struct InvalidConnectionTransition: Error, Hashable, Sendable {
    /// The state the event arrived in.
    public let state: ConnectionState
    /// The rejected event.
    public let event: ConnectionEvent
}

/// The legal transitions between ``ConnectionState`` values.
///
/// Pure and transport-agnostic: infrastructure reports events, the machine
/// decides the next state, and illegal events are rejected rather than ignored
/// so that sequencing bugs surface in tests and logs.
public struct ConnectionStateMachine: Hashable, Sendable {
    /// The retry policy applied to transient connection failures.
    public let retryPolicy: RetryPolicy

    /// Creates a state machine.
    public init(retryPolicy: RetryPolicy) {
        self.retryPolicy = retryPolicy
    }

    /// The state after `event` occurs in `state`.
    /// - Throws: ``InvalidConnectionTransition`` if the event is not legal in `state`.
    public func transition(
        from state: ConnectionState,
        on event: ConnectionEvent
    ) throws(InvalidConnectionTransition) -> ConnectionState {
        if let next = universalTransition(from: state, on: event) ?? stateSpecificTransition(from: state, on: event) {
            return next
        }
        throw InvalidConnectionTransition(state: state, event: event)
    }

    /// Device removal and host power events, which can arrive in any state.
    ///
    /// Host events are broadcast to every device, so they leave states without
    /// an active link unchanged instead of being rejected. A wake while a link
    /// is active (a missed sleep notification) still forces recovery so that
    /// device-side settings are re-applied.
    private func universalTransition(from state: ConnectionState, on event: ConnectionEvent) -> ConnectionState? {
        switch (state, event) {
        case (.disconnected(.removed), .deviceRemoved):
            nil
        case (_, .deviceRemoved):
            .disconnected(.removed)
        case (.discovered, .hostWillSleep), (.connecting, .hostWillSleep),
            (.connected, .hostWillSleep), (.recovering, .hostWillSleep):
            .suspended
        case (_, .hostWillSleep):
            state
        case (.suspended, .hostDidWake), (.connecting, .hostDidWake),
            (.connected, .hostDidWake), (.recovering, .hostDidWake):
            .recovering(cause: .hostWoke, failedAttempts: 0)
        case (_, .hostDidWake):
            state
        default:
            nil
        }
    }

    private func stateSpecificTransition(from state: ConnectionState, on event: ConnectionEvent) -> ConnectionState? {
        switch (state, event) {
        case (.discovered, .connectRequested),
            (.disconnected(.requested), .connectRequested),
            (.failed, .connectRequested):
            .connecting(attempt: 1)
        case (.connecting(let attempt), .connectFailed(let fault)):
            afterFailedAttempt(attempt, fault: fault)
        case (.connecting, .connectSucceeded):
            .connected
        case (.connected, .communicationLost):
            .recovering(cause: .unresponsive, failedAttempts: 0)
        case (.recovering(_, let failedAttempts), .connectRequested):
            .connecting(attempt: failedAttempts + 1)
        case (.connecting, .disconnectRequested), (.connected, .disconnectRequested),
            (.recovering, .disconnectRequested), (.suspended, .disconnectRequested),
            (.failed, .disconnectRequested):
            .disconnecting
        case (.disconnecting, .disconnectCompleted):
            .disconnected(.requested)
        case (.disconnected, .deviceDiscovered), (.failed, .deviceDiscovered):
            .discovered
        default:
            nil
        }
    }

    private func afterFailedAttempt(_ attempt: Int, fault: ConnectionFault) -> ConnectionState {
        switch fault {
        case .permanent(let permanent):
            .failed(permanent)
        case .transient(let transient):
            if attempt >= retryPolicy.maxConsecutiveFailures {
                .failed(.retriesExhausted)
            } else {
                .recovering(cause: .attemptFailed(transient), failedAttempts: attempt)
            }
        }
    }
}
