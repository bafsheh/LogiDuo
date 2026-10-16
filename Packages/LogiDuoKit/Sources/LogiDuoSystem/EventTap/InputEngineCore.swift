import Foundation
public import LogiDuoDomain

/// The decision for one tapped event.
public struct TapDecision: Hashable, Sendable {
    /// Whether to deliver the event.
    public let disposition: InputDisposition
    /// Input commands to perform after the callback returns.
    public let commands: [InputCommand]
    /// Tap lifecycle effects to perform.
    public let effects: [EventTapEffect]

    static let passThrough = TapDecision(disposition: .passThrough, commands: [], effects: [])
}

/// Counters for observability; never contain event contents.
public struct InputEngineStatistics: Hashable, Sendable {
    /// Events examined.
    public var examined = 0
    /// Events suppressed.
    public var suppressed = 0
    /// LogiDuo's own synthetic events seen by the tap (and passed through).
    public var syntheticSeen = 0
    /// Synthetic press commands issued.
    public var syntheticPresses = 0
    /// Synthetic release commands issued.
    public var syntheticReleases = 0
}

/// The synchronous decision core used by the event-tap callback.
///
/// Holds the ``InputInterpreter`` and ``EventTapSupervisor`` behind one lock.
/// Every method is short and allocation-light so it is safe to call from the
/// tap callback. While the supervisor is not `.active`, every event passes
/// through unchanged (fail-safe to native input).
public final class InputEngineCore: @unchecked Sendable {  // Invariant: all state guarded by `lock`.
    private let lock = NSLock()
    private var interpreter: InputInterpreter
    private var supervisor = EventTapSupervisor()
    private var stats = InputEngineStatistics()

    /// Creates a core with `mappings` (typically ``ResolvedMappings/passThrough`` at launch).
    public init(mappings: ResolvedMappings, gesture: GestureConfiguration = .standard) {
        interpreter = InputInterpreter(mappings: mappings, gesture: gesture)
    }

    /// The supervisor's state.
    public var tapState: EventTapState { lock.withLock { supervisor.state } }

    /// Counters so far.
    public var statistics: InputEngineStatistics { lock.withLock { stats } }

    /// Decides what to do with a tapped event at monotonic `time`.
    public func decide(_ snapshot: TapEventSnapshot, at time: Duration) -> TapDecision {
        let classification = TapEventClassifier.classify(snapshot)
        return lock.withLock {
            stats.examined += 1
            switch classification {
            case .signal(let signal):
                return lockedSignal(signal, at: time)
            case .ignore:
                if SyntheticEventMarker.isLogiDuoEvent(userData: snapshot.userData) { stats.syntheticSeen += 1 }
                return .passThrough
            case .input(let event):
                guard supervisor.state == .active else { return .passThrough }
                let response = interpreter.handle(event, at: time)
                if response.disposition == .suppress { stats.suppressed += 1 }
                count(response.commands)
                return TapDecision(disposition: response.disposition, commands: response.commands, effects: [])
            }
        }
    }

    /// Applies a lifecycle signal (start, stop, permission change, installation result).
    public func signal(_ signal: EventTapSignal, at time: Duration) -> TapDecision {
        lock.withLock { lockedSignal(signal, at: time) }
    }

    /// Swaps the mappings, finishing holds in progress safely.
    public func updateMappings(_ mappings: ResolvedMappings) -> [InputCommand] {
        lock.withLock {
            let commands = interpreter.updateMappings(mappings)
            count(commands)
            return commands
        }
    }

    /// Abandons every hold, returning releases for synthetic input still down.
    public func cancelHeldInput(at time: Duration) -> [InputCommand] {
        lock.withLock {
            let commands = interpreter.cancelAll(at: time)
            count(commands)
            return commands
        }
    }

    /// Releases synthetic presses held longer than the safety timeout.
    public func expireStalePresses(at time: Duration) -> [InputCommand] {
        lock.withLock {
            let commands = interpreter.expireStalePresses(at: time)
            count(commands)
            return commands
        }
    }

    private func lockedSignal(_ signal: EventTapSignal, at time: Duration) -> TapDecision {
        let effects = supervisor.handle(signal, at: time)
        var commands: [InputCommand] = []
        if effects.contains(.cancelHolds) {
            commands = interpreter.cancelAll(at: time)
            count(commands)
        }
        return TapDecision(disposition: .passThrough, commands: commands, effects: effects)
    }

    private func count(_ commands: [InputCommand]) {
        for command in commands {
            switch command {
            case .pressSynthetic: stats.syntheticPresses += 1
            case .releaseSynthetic: stats.syntheticReleases += 1
            default: break
            }
        }
    }
}
