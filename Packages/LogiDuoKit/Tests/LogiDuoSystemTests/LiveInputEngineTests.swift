import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoSystem
import Testing

/// A failure-injecting tap backend that records its lifecycle and lets tests deliver events.
final class FakeEventTapBackend: EventTapBackend, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var handler: EventTapHandler?
    private(set) var installs = 0
    private(set) var reenables = 0
    private(set) var removals = 0
    var refuseInstall = false

    var isInstalled: Bool { lock.withLock { handler != nil } }

    func install(mask: CGEventMask, handler: @escaping EventTapHandler) -> Bool {
        lock.withLock {
            installs += 1
            guard !refuseInstall else { return false }
            self.handler = handler
            return true
        }
    }

    func reenable() { lock.withLock { reenables += 1 } }

    func remove() {
        lock.withLock {
            if handler != nil { removals += 1 }
            handler = nil
        }
    }

    /// Delivers an event as the system would; returns what the tap returned (`nil` = suppressed).
    func deliver(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard let handler = lock.withLock({ self.handler }) else { return event }
        return handler(type, event)
    }
}

/// Records performed commands.
final class RecordingExecutor: InputCommandPerforming, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var log: [InputCommand] = []

    var commands: [InputCommand] { lock.withLock { log } }

    func perform(_ commands: [InputCommand]) {
        lock.withLock { log += commands }
    }
}

@Suite("LiveInputEngine with a fake tap", .serialized, .timeLimit(.minutes(1)))
struct LiveInputEngineTests {
    private static func mappings(_ mappings: ButtonMapping...) -> ResolvedMappings {
        guard let set = try? MappingSet(mappings) else { preconditionFailure("valid") }
        return MappingResolver.resolve(set, capabilities: .undiscovered, mode: .enabled)
    }

    private static func button(_ type: CGEventType, _ number: Int64, userData: Int64 = 0) -> CGEvent {
        guard
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: .zero,
                mouseButton: .center
            )
        else {
            preconditionFailure("CGEvent creation")
        }
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        return event
    }

    private static func disabledEvent(_ type: CGEventType) -> CGEvent {
        guard let event = CGEvent(source: nil) else { preconditionFailure("CGEvent creation") }
        event.type = type
        return event
    }

    private struct Clock: Sendable {
        let value = LockedDuration()
        var now: @Sendable () -> Duration { { [value] in value.get() } }
    }

    final class LockedDuration: @unchecked Sendable {  // Invariant: guarded by `lock`.
        private let lock = NSLock()
        private var current = Duration.zero
        func get() -> Duration { lock.withLock { current } }
        func advance(_ by: Duration) { lock.withLock { current += by } }
    }

    private struct Harness {
        let engine: LiveInputEngine
        let backend: FakeEventTapBackend
        let executor: RecordingExecutor
        let clock: LockedDuration
    }

    private func makeHarness(_ mappings: ResolvedMappings = .passThrough) -> Harness {
        let backend = FakeEventTapBackend()
        let executor = RecordingExecutor()
        let clock = Clock()
        let engine = LiveInputEngine(backend: backend, executor: executor, mappings: mappings, now: clock.now)
        return Harness(engine: engine, backend: backend, executor: executor, clock: clock.value)
    }

    @Test("starting installs the tap and becomes active; stopping removes it, idempotently")
    func lifecycle() {
        let harness = makeHarness()
        let engine = harness.engine
        let backend = harness.backend
        engine.start()
        #expect(engine.state == .active)
        #expect(backend.isInstalled)

        engine.stop()
        engine.stop()
        #expect(engine.state == .inactive)
        #expect(!backend.isInstalled)
        #expect(backend.removals == 1)
    }

    @Test("a refused installation suspends with native input and retries only when permission returns")
    func installationRefused() {
        let harness = makeHarness()
        let engine = harness.engine
        let backend = harness.backend
        backend.refuseInstall = true
        engine.start()
        #expect(engine.state == .suspended(.permissionMissing))
        engine.start()
        #expect(backend.installs == 1)

        backend.refuseInstall = false
        engine.permissionChanged(granted: true)
        #expect(engine.state == .active)
    }

    @Test("with remapping disabled every event passes through")
    func disabledPassesThrough() {
        let harness = makeHarness()
        let engine = harness.engine
        let backend = harness.backend
        let executor = harness.executor
        engine.start()
        let event = Self.button(.otherMouseDown, 3)
        #expect(backend.deliver(.otherMouseDown, event) === event)
        engine.drainCommands()
        #expect(executor.commands.isEmpty)
    }

    @Test("a mapped button is suppressed and its action performed off the callback")
    func mappedButton() {
        let harness = makeHarness(
            Self.mappings(ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)))
        )
        let engine = harness.engine
        let backend = harness.backend
        let executor = harness.executor
        engine.start()

        #expect(backend.deliver(.otherMouseDown, Self.button(.otherMouseDown, 3)) == nil)
        #expect(backend.deliver(.otherMouseUp, Self.button(.otherMouseUp, 3)) == nil)
        engine.drainCommands()
        #expect(executor.commands == [.perform(.shortcut(.browserBack))])
    }

    @Test("regression: a suppressed event is not delivered by the tap handler")
    func suppressionIsNotUndone() {
        let harness = makeHarness(
            Self.mappings(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
        )
        let engine = harness.engine
        let backend = harness.backend
        engine.start()

        #expect(backend.deliver(.otherMouseDown, Self.button(.otherMouseDown, 4)) == nil)
        #expect(backend.deliver(.otherMouseUp, Self.button(.otherMouseUp, 4)) == nil)
        #expect(engine.statistics.suppressed == 2)
    }

    @Test("LogiDuo's own marked events pass through untouched (no recursion)")
    func syntheticPassThrough() {
        let harness = makeHarness(
            Self.mappings(ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)))
        )
        let engine = harness.engine
        let backend = harness.backend
        let executor = harness.executor
        engine.start()
        let synthetic = Self.button(.otherMouseDown, 3, userData: SyntheticEventMarker.value)

        #expect(backend.deliver(.otherMouseDown, synthetic) === synthetic)
        engine.drainCommands()
        #expect(executor.commands.isEmpty)
        #expect(engine.statistics.syntheticSeen == 1)
    }

    @Test("a timed-out tap is re-enabled; three timeouts in ten seconds remove it and restore native input")
    func timeouts() {
        let harness = makeHarness(
            Self.mappings(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
        )
        let engine = harness.engine
        let backend = harness.backend
        let executor = harness.executor
        let clock = harness.clock
        engine.start()
        _ = backend.deliver(.otherMouseDown, Self.button(.otherMouseDown, 4))

        _ = backend.deliver(.tapDisabledByTimeout, Self.disabledEvent(.tapDisabledByTimeout))
        #expect(backend.reenables == 1)
        clock.advance(.seconds(1))
        _ = backend.deliver(.tapDisabledByTimeout, Self.disabledEvent(.tapDisabledByTimeout))
        clock.advance(.seconds(1))
        _ = backend.deliver(.tapDisabledByTimeout, Self.disabledEvent(.tapDisabledByTimeout))
        engine.stop()

        #expect(backend.reenables == 2)
        #expect(!backend.isInstalled)
        #expect(executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
    }

    @Test("stopping while a synthetic press is held releases it before the tap is removed")
    func stopReleasesHeldInput() {
        let harness = makeHarness(
            Self.mappings(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
        )
        let engine = harness.engine
        let backend = harness.backend
        let executor = harness.executor
        engine.start()
        _ = backend.deliver(.otherMouseDown, Self.button(.otherMouseDown, 4))

        engine.stop()

        #expect(executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
        let laterUp = Self.button(.otherMouseUp, 4)
        #expect(backend.deliver(.otherMouseUp, laterUp) === laterUp)
    }

    @Test("revoking permission releases held input and removes the tap")
    func permissionRevoked() {
        let harness = makeHarness(
            Self.mappings(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
        )
        let engine = harness.engine
        let backend = harness.backend
        let executor = harness.executor
        engine.start()
        _ = backend.deliver(.otherMouseDown, Self.button(.otherMouseDown, 4))

        engine.permissionChanged(granted: false)
        engine.drainCommands()

        #expect(engine.state == .suspended(.permissionMissing))
        #expect(!backend.isInstalled)
        #expect(executor.commands.last == .releaseSynthetic(.middle))
    }

    @Test("disabling remapping mid-press releases the synthetic press once")
    func disableMidPress() {
        let harness = makeHarness(
            Self.mappings(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
        )
        let engine = harness.engine
        let backend = harness.backend
        let executor = harness.executor
        engine.start()
        _ = backend.deliver(.otherMouseDown, Self.button(.otherMouseDown, 4))

        engine.updateMappings(.passThrough)
        #expect(backend.deliver(.otherMouseUp, Self.button(.otherMouseUp, 4)) == nil)
        engine.drainCommands()

        #expect(executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
    }

    @Test("the tap mask excludes primary and secondary buttons and the keyboard")
    func mask() {
        let mask = LogiDuoEventMask.value
        for type in [
            CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown, .keyUp, .flagsChanged,
        ] {
            #expect(mask & (CGEventMask(1) << CGEventMask(type.rawValue)) == 0, "\(type.rawValue)")
        }
        for type in [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .scrollWheel] {
            #expect(mask & (CGEventMask(1) << CGEventMask(type.rawValue)) != 0)
        }
    }
}
