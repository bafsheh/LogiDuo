import CoreGraphics
import Foundation
public import LogiDuoDomain

/// Performs input commands produced by the engine (synthetic clicks, shortcuts, actions).
public protocol InputCommandPerforming: Sendable {
    /// Performs `commands` in order. Called on the engine's command queue, never in the tap callback.
    func perform(_ commands: [InputCommand])
}

/// The live input engine: the system event tap connected to the tested domain core.
///
/// Threading: the tap callback runs on the backend's run-loop thread and only
/// classifies the event and asks ``InputEngineCore`` for a decision. Commands
/// and tap effects are executed afterwards on serial queues. Public methods may
/// be called from any thread.
///
/// Safety: remapping starts disabled (``ResolvedMappings/passThrough``); stopping,
/// a failed installation, revoked permission or repeated timeouts all remove the
/// tap after releasing held input, so input falls back to native behavior.
public final class LiveInputEngine: Sendable {
    /// Supervisor states, in order.
    public let states: AsyncStream<EventTapState>

    private let core: InputEngineCore
    private let backend: any EventTapBackend
    private let executor: any InputCommandPerforming
    private let now: @Sendable () -> Duration
    private let commandQueue = DispatchQueue(label: "io.github.bafsheh.LogiDuo.input.commands")
    private let controlQueue = DispatchQueue(label: "io.github.bafsheh.LogiDuo.input.control")
    private let stateSink: AsyncStream<EventTapState>.Continuation
    private let scroll = LockedScrollSettings()

    /// Creates an engine. Nothing is tapped until ``start()``.
    public init(
        backend: any EventTapBackend = CoreGraphicsEventTapBackend(),
        executor: any InputCommandPerforming,
        mappings: ResolvedMappings = .passThrough,
        now: @escaping @Sendable () -> Duration = LiveInputEngine.monotonicNow
    ) {
        self.core = InputEngineCore(mappings: mappings)
        self.backend = backend
        self.executor = executor
        self.now = now
        (states, stateSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    deinit {
        // An engine released without stop() must not leave a tap behind; its handler
        // already passes every event through once the engine is gone.
        backend.remove()
    }

    /// Monotonic time since an arbitrary origin.
    public static let monotonicNow: @Sendable () -> Duration = {
        let origin = ContinuousClock.now
        return { ContinuousClock.now - origin }
    }()

    /// The supervisor's current state.
    public var state: EventTapState { core.tapState }

    /// Counters so far.
    public var statistics: InputEngineStatistics { core.statistics }

    /// Requests interception. Returns after the installation attempt.
    public func start() {
        controlQueue.sync { apply(core.signal(.startRequested, at: now())) }
    }

    /// Stops interception: releases held input, then removes the tap. Idempotent.
    public func stop() {
        controlQueue.sync { apply(core.signal(.stopRequested, at: now())) }
        commandQueue.sync {}
    }

    /// Reports a permission change observed by the permissions service.
    public func permissionChanged(granted: Bool) {
        controlQueue.sync { apply(core.signal(granted ? .permissionGranted : .permissionRevoked, at: now())) }
    }

    /// Swaps the mappings (profile switch, remapping toggled); held input is finished safely.
    public func updateMappings(_ mappings: ResolvedMappings) {
        let commands = core.updateMappings(mappings)
        enqueue(commands)
        commandQueue.sync {}
    }

    /// Feeds an event the device reported over HID++ (a diverted button or raw motion).
    public func deviceInput(_ event: InputEvent) {
        enqueue(core.deviceInput(event, at: now()))
    }

    /// Replaces the scroll preferences (inversion, Shift for horizontal, trackpad exclusion).
    public func updateScrollSettings(_ settings: ScrollSettings) {
        scroll.value = settings
    }

    /// Releases all held synthetic input without stopping interception (for example before sleep).
    public func cancelHeldInput() {
        enqueue(core.cancelHeldInput(at: now()))
        commandQueue.sync {}
    }

    /// Releases synthetic presses whose physical up never arrived; call periodically.
    public func expireStalePresses() {
        enqueue(core.expireStalePresses(at: now()))
    }

    /// Waits until every command produced so far has been performed (for orderly shutdown and tests).
    public func drainCommands() {
        commandQueue.sync {}
    }

    // MARK: - Callback path

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let decision = core.decide(Self.snapshot(type, event), at: now())
        enqueue(decision.commands)
        if !decision.effects.isEmpty {
            perform(effectsFromCallback: decision.effects)
        }
        guard decision.disposition != .suppress else { return nil }
        if type == .scrollWheel { Self.applyScroll(scroll.value, to: event) }
        return event
    }

    /// Rewrites a delivered scroll event according to `settings` (only LogiDuo's own
    /// synthetic events are never touched; they are classified as ignored and
    /// carry no wheel deltas).
    static func applyScroll(_ settings: ScrollSettings, to event: CGEvent) {
        guard !SyntheticEventMarker.isLogiDuoEvent(userData: event.getIntegerValueField(.eventSourceUserData)) else {
            return
        }
        let fields = ScrollFields(
            vertical: ScrollAxis(
                lines: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                points: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            ),
            horizontal: ScrollAxis(
                lines: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                points: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            ),
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            shift: event.flags.contains(.maskShift)
        )
        guard let changed = ScrollTransform.apply(settings, to: fields) else { return }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: changed.vertical.lines)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: changed.vertical.fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: changed.vertical.points)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: changed.horizontal.lines)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: changed.horizontal.fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: changed.horizontal.points)
    }

    /// Re-enabling must happen immediately; everything else is deferred off the callback.
    private func perform(effectsFromCallback effects: [EventTapEffect]) {
        if effects.contains(.reenableTap) { backend.reenable() }
        let deferred = effects.filter { $0 != .reenableTap && $0 != .cancelHolds }
        guard !deferred.isEmpty else { return }
        controlQueue.async { [self] in
            perform(deferred)
            stateSink.yield(core.tapState)
        }
    }

    private func apply(_ decision: TapDecision) {
        enqueue(decision.commands)
        perform(decision.effects.filter { $0 != .cancelHolds })
        stateSink.yield(core.tapState)
    }

    /// Runs tap effects on the control queue.
    private func perform(_ effects: [EventTapEffect]) {
        for effect in effects {
            switch effect {
            case .installTap:
                let installed = backend.install(mask: LogiDuoEventMask.value) { [weak self] type, event in
                    // Explicit unwrap: `self?.handle(...) ?? event` would turn a deliberate
                    // suppression (nil) back into delivery.
                    guard let self else { return event }
                    return self.handle(type, event)
                }
                apply(core.signal(installed ? .tapInstalled : .tapInstallationFailed, at: now()))
            case .reenableTap:
                backend.reenable()
            case .removeTap:
                commandQueue.sync {}
                backend.remove()
            case .cancelHolds, .notify:
                break
            }
        }
    }

    private func enqueue(_ commands: [InputCommand]) {
        guard !commands.isEmpty else { return }
        commandQueue.async { [executor] in executor.perform(commands) }
    }

    static func snapshot(_ type: CGEventType, _ event: CGEvent) -> TapEventSnapshot {
        let kind: TapEventSnapshot.Kind =
            switch type {
            case .otherMouseDown: .otherMouseDown
            case .otherMouseUp: .otherMouseUp
            case .otherMouseDragged: .otherMouseDragged
            case .mouseMoved: .mouseMoved
            case .scrollWheel: .scrollWheel
            case .tapDisabledByTimeout: .tapDisabledByTimeout
            case .tapDisabledByUserInput: .tapDisabledByUserInput
            default: .other
            }
        return TapEventSnapshot(
            kind: kind,
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            userData: event.getIntegerValueField(.eventSourceUserData),
            deltaX: event.getIntegerValueField(.mouseEventDeltaX),
            deltaY: event.getIntegerValueField(.mouseEventDeltaY),
            horizontalScroll: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        )
    }
}

/// Scroll settings shared between the control side and the tap callback.
private final class LockedScrollSettings: @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private var stored = ScrollSettings.standard

    var value: ScrollSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
