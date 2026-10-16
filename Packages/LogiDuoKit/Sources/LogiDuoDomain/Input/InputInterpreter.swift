/// A physical input event, as observed by the system layer.
public enum InputEvent: Hashable, Sendable {
    /// A button went down.
    case buttonDown(MouseButton)
    /// A button went up.
    case buttonUp(MouseButton)
    /// Pointer movement (event tap) or device raw XY, in device units.
    case motion(dx: Double, dy: Double, source: MotionSource)
    /// Horizontal scrolling; `delta` is the magnitude if known.
    case horizontalScroll(HorizontalScrollDirection, delta: Double?)
}

/// What should happen to the original event.
public enum InputDisposition: Hashable, Sendable {
    /// Deliver the event unchanged: native behavior.
    case passThrough
    /// Swallow the event.
    case suppress
}

/// Side effects the system layer must perform, in order.
public enum InputCommand: Hashable, Sendable {
    /// Perform a one-shot action (shortcut, media, system, device, application).
    case perform(Action)
    /// Press a synthetic mouse button; always followed later by ``releaseSynthetic(_:)``.
    case pressSynthetic(SyntheticButton)
    /// Release a synthetic mouse button.
    case releaseSynthetic(SyntheticButton)
    /// Re-create the native click of a button whose press was held back to detect swipes.
    case replayNativeClick(MouseButton)
}

/// The decision for one event.
public struct InputResponse: Hashable, Sendable {
    /// What happens to the original event.
    public let disposition: InputDisposition
    /// Commands to perform, in order.
    public let commands: [InputCommand]

    /// Creates a response.
    public init(disposition: InputDisposition, commands: [InputCommand]) {
        self.disposition = disposition
        self.commands = commands
    }

    static let passThrough = InputResponse(disposition: .passThrough, commands: [])
    static let suppress = InputResponse(disposition: .suppress, commands: [])

    static func suppress(_ commands: [InputCommand]) -> InputResponse {
        InputResponse(disposition: .suppress, commands: commands)
    }
}

/// Decides, for every input event, between native pass-through and a mapped action.
///
/// A pure reducer over ``ResolvedMappings``. Invariants:
/// * Primary and secondary buttons always pass through.
/// * The handling of a button's *up* is fixed when its *down* arrives, so
///   changing mappings or profiles mid-press never strands a press: a
///   suppressed down always gets a suppressed up, a passed-through down a
///   passed-through up, and an up with no recorded down passes through.
/// * Every ``InputCommand/pressSynthetic(_:)`` is matched by exactly one release:
///   on the physical up, on ``cancelAll(at:)``, on ``updateMappings(_:)`` or after
///   ``syntheticPressTimeout``. Synthetic presses are reference-counted per
///   button, so overlapping holders produce one press and one release, and a
///   one-shot click (or native-click replay) of a button that is held
///   synthetically is skipped rather than releasing it early.
/// * One-shot actions fire on the down (as in Mouser). Buttons with swipe
///   mappings hold their press back; the up runs the tap (the press action, or
///   a replay of the native click) only if no swipe fired.
public struct InputInterpreter: Hashable, Sendable {
    /// After this long without the physical up, a synthetic press is released (Mouser's safety timer).
    public static let syntheticPressTimeout = Duration.seconds(20)

    private enum Hold: Hashable {
        case passedThrough
        case consumed
        case synthetic(SyntheticButton, since: Duration)
        case gesture(GestureRecognizer, tap: Action)
    }

    /// The mappings in effect.
    public private(set) var mappings: ResolvedMappings
    private let gestureConfiguration: GestureConfiguration
    private var holds: [MouseButton: Hold] = [:]
    private var syntheticDepth: [SyntheticButton: Int] = [:]
    private var scroll: HorizontalScrollAccumulator

    /// Creates an interpreter.
    public init(
        mappings: ResolvedMappings,
        gesture: GestureConfiguration = .standard,
        scrollThreshold: Double = HorizontalScrollAccumulator.defaultThreshold
    ) {
        self.mappings = mappings
        self.gestureConfiguration = gesture
        self.scroll = HorizontalScrollAccumulator(threshold: scrollThreshold)
    }

    /// Handles one event at monotonic `time`.
    public mutating func handle(_ event: InputEvent, at time: Duration) -> InputResponse {
        switch event {
        case .buttonDown(let button): buttonDown(button, at: time)
        case .buttonUp(let button): buttonUp(button)
        case .motion(let dx, let dy, let source): motion(dx: dx, dy: dy, source: source, at: time)
        case .horizontalScroll(let direction, let delta): horizontalScroll(direction, delta: delta, at: time)
        }
    }

    /// Swaps the mappings (profile switch, capability change, remapping toggled).
    ///
    /// Holds in progress are finished safely: synthetic presses are released,
    /// gestures are cancelled without a tap, and the pending ups stay suppressed.
    public mutating func updateMappings(_ new: ResolvedMappings) -> [InputCommand] {
        let commands = finishHolds()
        mappings = new
        return commands
    }

    /// Abandons every hold (permission loss, disconnect, sleep, quit).
    /// - Returns: Releases for every synthetic press still held.
    public mutating func cancelAll(at _: Duration) -> [InputCommand] {
        finishHolds()
    }

    /// Releases synthetic presses whose physical up has not arrived within ``syntheticPressTimeout``.
    public mutating func expireStalePresses(at time: Duration) -> [InputCommand] {
        var commands: [InputCommand] = []
        for (button, hold) in holds.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if case .synthetic(let target, let since) = hold, time - since >= Self.syntheticPressTimeout {
                commands += relinquish(target)
                holds[button] = .consumed
            }
        }
        return commands
    }

    // MARK: - Buttons

    private mutating func buttonDown(_ button: MouseButton, at time: Duration) -> InputResponse {
        guard !button.isProtected else { return .passThrough }
        if let existing = holds[button] {
            return existing == .passedThrough ? .passThrough : .suppress
        }
        if mappings.swipeButtons.contains(button) {
            var recognizer = GestureRecognizer(configuration: gestureConfiguration)
            recognizer.begin()
            holds[button] = .gesture(recognizer, tap: mappings.action(for: .press(button)))
            return .suppress
        }
        switch mappings.action(for: .press(button)) {
        case .passThrough, .unsupported:
            holds[button] = .passedThrough
            return .passThrough
        case .click(let target):
            holds[button] = .synthetic(target, since: time)
            return .suppress(acquire(target))
        case let action:
            holds[button] = .consumed
            return .suppress([.perform(action)])
        }
    }

    private mutating func buttonUp(_ button: MouseButton) -> InputResponse {
        guard !button.isProtected, let hold = holds.removeValue(forKey: button) else { return .passThrough }
        switch hold {
        case .passedThrough:
            return .passThrough
        case .consumed:
            return .suppress
        case .synthetic(let target, _):
            return .suppress(relinquish(target))
        case .gesture(var recognizer, let tap):
            guard recognizer.end() == .tap else { return .suppress }
            return .suppress(tapCommands(for: button, tap: tap))
        }
    }

    /// A tap runs the press action, or replays the native click when the press is not mapped.
    private func tapCommands(for button: MouseButton, tap: Action) -> [InputCommand] {
        guard tap.isPassThrough else { return commands(for: tap) }
        let alreadyDown = SyntheticButton(rawValue: button.rawValue).map { syntheticDepth[$0, default: 0] > 0 } ?? false
        return alreadyDown ? [] : [.replayNativeClick(button)]
    }

    /// The commands that perform `action` once.
    private func commands(for action: Action) -> [InputCommand] {
        switch action {
        case .passThrough, .unsupported: []
        case .click(let target):
            syntheticDepth[target, default: 0] > 0 ? [] : [.pressSynthetic(target), .releaseSynthetic(target)]
        default: [.perform(action)]
        }
    }

    /// Takes a reference on `target`, pressing it if it was up.
    private mutating func acquire(_ target: SyntheticButton) -> [InputCommand] {
        syntheticDepth[target, default: 0] += 1
        return syntheticDepth[target] == 1 ? [.pressSynthetic(target)] : []
    }

    /// Drops a reference on `target`, releasing it when no holder remains.
    private mutating func relinquish(_ target: SyntheticButton) -> [InputCommand] {
        let depth = syntheticDepth[target, default: 0]
        guard depth > 0 else { return [] }
        syntheticDepth[target] = depth == 1 ? nil : depth - 1
        return depth == 1 ? [.releaseSynthetic(target)] : []
    }

    // MARK: - Motion and scrolling

    private mutating func motion(dx: Double, dy: Double, source: MotionSource, at time: Duration) -> InputResponse {
        var commands: [InputCommand] = []
        var holdingGesture = false
        for (button, hold) in holds.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard case .gesture(var recognizer, let tap) = hold else { continue }
            holdingGesture = true
            if let direction = recognizer.sample(dx: dx, dy: dy, source: source, at: time) {
                commands += self.commands(for: mappings.action(for: .swipe(button, direction)))
            }
            holds[button] = .gesture(recognizer, tap: tap)
        }
        // While a gesture is held the cursor stays still, as in Mouser.
        return holdingGesture ? .suppress(commands) : .passThrough
    }

    private mutating func horizontalScroll(
        _ direction: HorizontalScrollDirection,
        delta: Double?,
        at time: Duration
    ) -> InputResponse {
        let action = mappings.action(for: .horizontalScroll(direction))
        guard !action.isPassThrough else { return .passThrough }
        let cooldown = HorizontalScrollAccumulator.cooldown(for: action)
        guard scroll.feed(direction, delta: delta, cooldown: cooldown, at: time) else { return .suppress }
        return .suppress(commands(for: action))
    }

    // MARK: - Cancellation

    /// Releases synthetic presses, cancels gestures, and keeps pending ups suppressed.
    private mutating func finishHolds() -> [InputCommand] {
        var commands: [InputCommand] = []
        for (button, hold) in holds.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            switch hold {
            case .passedThrough, .consumed:
                continue
            case .synthetic(let target, _):
                commands += relinquish(target)
                holds[button] = .consumed
            case .gesture:
                holds[button] = .consumed
            }
        }
        return commands
    }
}
