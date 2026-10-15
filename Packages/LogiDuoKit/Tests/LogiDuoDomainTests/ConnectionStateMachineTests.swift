import LogiDuoDomain
import Testing

@Suite("ConnectionStateMachine")
struct ConnectionStateMachineTests {
    private static let maxFailures = 3
    private let machine = ConnectionStateMachine(retryPolicy: Self.policy)

    private static let policy: RetryPolicy = {
        guard let policy = RetryPolicy(maxConsecutiveFailures: maxFailures) else {
            preconditionFailure("a positive retry count is valid")
        }
        return policy
    }()

    /// One representative of every state shape.
    static let states: [ConnectionState] = [
        .discovered,
        .connecting(attempt: 1),
        .connected,
        .disconnecting,
        .disconnected(.requested),
        .disconnected(.removed),
        .recovering(cause: .unresponsive, failedAttempts: 0),
        .suspended,
        .failed(.accessDenied),
    ]

    /// One representative of every event shape.
    static let events: [ConnectionEvent] = [
        .connectRequested,
        .connectSucceeded,
        .connectFailed(.transient(.timeout)),
        .connectFailed(.permanent(.unsupportedProtocol)),
        .communicationLost,
        .disconnectRequested,
        .disconnectCompleted,
        .deviceRemoved,
        .deviceDiscovered,
        .hostWillSleep,
        .hostDidWake,
    ]

    /// The complete, independently written transition table for the representatives.
    /// Pairs absent from this table must be rejected.
    static let expected: [Pair: ConnectionState] = universalRows().merging(specificRows()) { _, specific in specific }

    /// Removal and host power events.
    private static func universalRows() -> [Pair: ConnectionState] {
        var table: [Pair: ConnectionState] = [:]
        let woke = ConnectionState.recovering(cause: .hostWoke, failedAttempts: 0)
        for state in states {
            if state != .disconnected(.removed) {
                table[Pair(state: state, event: .deviceRemoved)] = .disconnected(.removed)
            }
            switch state {
            case .discovered, .connecting, .connected, .recovering:
                table[Pair(state: state, event: .hostWillSleep)] = .suspended
            default:
                table[Pair(state: state, event: .hostWillSleep)] = state
            }
            switch state {
            case .suspended, .connecting, .connected, .recovering:
                table[Pair(state: state, event: .hostDidWake)] = woke
            default:
                table[Pair(state: state, event: .hostDidWake)] = state
            }
        }
        return table
    }

    /// Lifecycle transitions specific to each state.
    private static func specificRows() -> [Pair: ConnectionState] {
        let recovering = ConnectionState.recovering(cause: .unresponsive, failedAttempts: 0)
        let rows: [(ConnectionState, ConnectionEvent, ConnectionState)] = [
            (.discovered, .connectRequested, .connecting(attempt: 1)),
            (.connecting(attempt: 1), .connectSucceeded, .connected),
            (
                .connecting(attempt: 1), .connectFailed(.transient(.timeout)),
                .recovering(cause: .attemptFailed(.timeout), failedAttempts: 1)
            ),
            (.connecting(attempt: 1), .connectFailed(.permanent(.unsupportedProtocol)), .failed(.unsupportedProtocol)),
            (.connecting(attempt: 1), .disconnectRequested, .disconnecting),
            (.connected, .communicationLost, recovering),
            (.connected, .disconnectRequested, .disconnecting),
            (.disconnecting, .disconnectCompleted, .disconnected(.requested)),
            (.disconnected(.requested), .connectRequested, .connecting(attempt: 1)),
            (.disconnected(.requested), .deviceDiscovered, .discovered),
            (.disconnected(.removed), .deviceDiscovered, .discovered),
            (recovering, .connectRequested, .connecting(attempt: 1)),
            (recovering, .disconnectRequested, .disconnecting),
            (.suspended, .disconnectRequested, .disconnecting),
            (.failed(.accessDenied), .connectRequested, .connecting(attempt: 1)),
            (.failed(.accessDenied), .disconnectRequested, .disconnecting),
            (.failed(.accessDenied), .deviceDiscovered, .discovered),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { (Pair(state: $0.0, event: $0.1), $0.2) })
    }

    struct Pair: Hashable, Sendable {
        let state: ConnectionState
        let event: ConnectionEvent
    }

    @Test("every state and event pair matches the transition table")
    func exhaustiveTable() {
        for state in Self.states {
            for event in Self.events {
                let pair = Pair(state: state, event: event)
                if let next = Self.expected[pair] {
                    #expect((try? machine.transition(from: state, on: event)) == next, "\(state) + \(event)")
                } else {
                    let error = #expect(throws: InvalidConnectionTransition.self, "\(state) + \(event)") {
                        try machine.transition(from: state, on: event)
                    }
                    #expect(error?.state == state && error?.event == event)
                }
            }
        }
    }

    @Test("retries transient failures until the policy gives up")
    func retryExhaustion() throws {
        var state = ConnectionState.discovered
        var visited: [ConnectionState] = []
        state = try machine.transition(from: state, on: .connectRequested)
        for _ in 1...Self.maxFailures {
            visited.append(state)
            state = try machine.transition(from: state, on: .connectFailed(.transient(.busy)))
            if case .recovering = state {
                state = try machine.transition(from: state, on: .connectRequested)
            }
        }

        #expect(visited == [.connecting(attempt: 1), .connecting(attempt: 2), .connecting(attempt: 3)])
        #expect(state == .failed(.retriesExhausted))
    }

    @Test("a successful attempt resets the failure count")
    func successResetsFailures() throws {
        var state = try machine.transition(from: .connecting(attempt: 2), on: .connectSucceeded)
        state = try machine.transition(from: state, on: .communicationLost)
        state = try machine.transition(from: state, on: .connectRequested)

        #expect(state == .connecting(attempt: 1))
    }

    @Test("permanent faults fail immediately on any attempt", arguments: PermanentFault.allCases)
    func permanentFaults(fault: PermanentFault) throws {
        #expect(
            try machine.transition(from: .connecting(attempt: 1), on: .connectFailed(.permanent(fault)))
                == .failed(fault)
        )
    }

    @Test("regression: waking the Mac always re-applies device settings through connecting")
    func wakeGoesThroughConnecting() throws {
        var state = try machine.transition(from: .connected, on: .hostWillSleep)
        #expect(state == .suspended)
        state = try machine.transition(from: state, on: .hostDidWake)
        #expect(!state.acceptsCommands)
        #expect(throws: InvalidConnectionTransition.self) {
            try machine.transition(from: state, on: .connectSucceeded)
        }
        state = try machine.transition(from: state, on: .connectRequested)
        #expect(state == .connecting(attempt: 1))
    }

    @Test("regression: a device that stops answering is reconfigured before accepting commands")
    func unresponsiveDeviceIsReconfigured() throws {
        let state = try machine.transition(from: .connected, on: .communicationLost)

        #expect(state == .recovering(cause: .unresponsive, failedAttempts: 0))
        #expect(!state.acceptsCommands)
    }

    @Test(
        "regression: closing an active link always passes through disconnecting",
        arguments: [
            ConnectionState.connecting(attempt: 1), .connected, .recovering(cause: .hostWoke, failedAttempts: 0),
            .suspended,
        ]
    )
    func closeRestoresDefaults(state: ConnectionState) throws {
        #expect(try machine.transition(from: state, on: .disconnectRequested) == .disconnecting)
    }

    @Test("a removed device cannot be reconnected until it is rediscovered")
    func removedRequiresDiscovery() throws {
        #expect(throws: InvalidConnectionTransition.self) {
            try machine.transition(from: .disconnected(.removed), on: .connectRequested)
        }
        let rediscovered = try machine.transition(from: .disconnected(.removed), on: .deviceDiscovered)
        #expect(try machine.transition(from: rediscovered, on: .connectRequested) == .connecting(attempt: 1))
    }

    @Test("only the connected state accepts commands", arguments: states)
    func commandGate(state: ConnectionState) {
        #expect(state.acceptsCommands == (state == .connected))
    }

    @Test("retry policy rejects values below one", arguments: [-1, 0])
    func retryPolicyValidation(value: Int) {
        #expect(RetryPolicy(maxConsecutiveFailures: value) == nil)
    }

    @Test("transient faults are recoverable and permanent ones are not")
    func faultRecoverability() {
        #expect(TransientFault.allCases.allSatisfy { ConnectionFault.transient($0).isRecoverable })
        #expect(PermanentFault.allCases.allSatisfy { !ConnectionFault.permanent($0).isRecoverable })
    }
}
