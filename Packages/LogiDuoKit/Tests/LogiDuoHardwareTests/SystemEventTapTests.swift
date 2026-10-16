import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoSystem
import Testing

/// Records commands (4.1 verifies interception only; synthesis is verified separately).
final class SystemRecordingExecutor: InputCommandPerforming, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var log: [InputCommand] = []
    var commands: [InputCommand] { lock.withLock { log } }
    func perform(_ commands: [InputCommand]) { lock.withLock { log += commands } }
}

/// Wraps the real backend; stalls the callback on a test-marked button-8 down to provoke a real tap timeout.
final class StallingBackend: EventTapBackend, @unchecked Sendable {  // Invariant: counters guarded by `lock`.
    private let inner = CoreGraphicsEventTapBackend()
    private let condition = NSCondition()
    private var reenableCount = 0
    let stall = DispatchSemaphore(value: 0)

    var reenables: Int { condition.withLock { reenableCount } }

    /// Waits for the engine to re-enable the tap; `timeout` only bounds a failing wait.
    func waitForReenable(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while reenableCount == 0 {
            guard condition.wait(until: deadline) else { return reenableCount > 0 }
        }
        return true
    }
    var isInstalled: Bool { inner.isInstalled }

    func install(mask: CGEventMask, handler: @escaping EventTapHandler) -> Bool {
        inner.install(mask: mask) { [stall] type, event in
            if type == .otherMouseDown, event.getIntegerValueField(.mouseEventButtonNumber) == 8,
                event.getIntegerValueField(.eventSourceUserData) == testInjectionMarker
            {
                // Blocks the tap callback (bounded) so macOS disables the tap for timing out.
                _ = stall.wait(timeout: .now() + 3)
            }
            return handler(type, event)
        }
    }

    func reenable() {
        inner.reenable()
        condition.withLock {
            reenableCount += 1
            condition.broadcast()
        }
    }

    func remove() { inner.remove() }
}

extension LiveSystemSuites {
    @Suite("System: live event tap (test-marked events only)", .timeLimit(.minutes(2)))
    struct SystemEventTapTests {
        private static func mapping(_ mappings: ButtonMapping...) -> ResolvedMappings {
            guard let set = try? MappingSet(mappings) else { preconditionFailure("valid") }
            return MappingResolver.resolve(set, capabilities: .undiscovered, mode: .enabled)
        }

        /// F19 without modifiers: normally unbound, harmless if it ever leaked.
        private static let f19: KeyboardShortcut = {
            guard let key = KeyCode(rawValue: 0x50), let shortcut = KeyboardShortcut(key: key, modifiers: []) else {
                preconditionFailure("F19 is a valid shortcut")
            }
            return shortcut
        }()

        /// Starts the sink and proves it swallows test events before anything else is injected.
        private static func armedSink() throws -> EventSink {
            let sink = EventSink()
            try #require(sink.start(), "sink tap could not be created (Accessibility?)")
            Injector.click(number: 9)
            let armed = sink.wait { records in records.filter { $0.button == 9 }.count >= 2 }
            if !armed { sink.stop() }
            try #require(armed, "sink did not receive the probe; aborting before any further injection")
            sink.clear()
            return sink
        }

        private static func count(_ records: [SinkRecord], button: Int64) -> Int {
            records.filter { $0.button == button && $0.userData == testInjectionMarker }.count
        }

        @Test("observing: with remapping disabled, events pass through unmodified")
        func observeOnly() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            let executor = SystemRecordingExecutor()
            let engine = LiveInputEngine(executor: executor)
            engine.start()
            defer { engine.stop() }
            try #require(engine.state == EventTapState.active, "event tap could not be installed")

            Injector.click(number: 3)
            #expect(sink.wait { Self.count($0, button: 3) == 2 })
            engine.drainCommands()
            #expect(executor.commands.isEmpty)
            #expect(engine.statistics.examined >= 2)
        }

        @Test("left and right clicks are untouched while a mapping is active")
        func primaryAndSecondaryUntouched() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            let executor = SystemRecordingExecutor()
            let engine = LiveInputEngine(
                executor: executor,
                mappings: Self.mapping(
                    ButtonMapping(trigger: .press(.back), action: .customShortcut(Self.f19))
                )
            )
            engine.start()
            defer { engine.stop() }

            Injector.click(number: 0)
            Injector.click(number: 1)
            #expect(sink.wait { Self.count($0, button: 0) == 2 && Self.count($0, button: 1) == 2 })
            engine.drainCommands()
            #expect(executor.commands.isEmpty)
        }

        @Test("a mapped button is suppressed in the real pipeline and its action requested once")
        func suppression() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            let executor = SystemRecordingExecutor()
            let engine = LiveInputEngine(
                executor: executor,
                mappings: Self.mapping(
                    ButtonMapping(trigger: .press(.back), action: .customShortcut(Self.f19))
                )
            )
            engine.start()
            defer { engine.stop() }

            Injector.click(number: 3)
            Injector.click(number: 9)
            #expect(sink.wait { Self.count($0, button: 9) == 2 })
            engine.drainCommands()
            #expect(Self.count(sink.all, button: 3) == 0)
            #expect(executor.commands == [.perform(.customShortcut(Self.f19))])
        }

        @Test("macOS disabling the tap for a slow callback is recovered by re-enabling it")
        func realTimeoutRecovery() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            let backend = StallingBackend()
            let executor = SystemRecordingExecutor()
            let engine = LiveInputEngine(
                backend: backend,
                executor: executor,
                mappings: Self.mapping(
                    ButtonMapping(trigger: .press(.back), action: .customShortcut(Self.f19))
                )
            )
            engine.start()
            defer { engine.stop() }

            Injector.button(.otherMouseDown, number: 8)
            Injector.button(.otherMouseUp, number: 8)
            #expect(sink.wait(timeout: 6) { Self.count($0, button: 8) == 2 })
            // Events posted while the tap is disabled bypass it; nudge until macOS reports the timeout.
            var nudges = 0
            while backend.reenables == 0, nudges < 20 {
                Injector.click(number: 9)
                nudges += 1
                _ = backend.waitForReenable(timeout: 0.25)
            }
            try #require(backend.waitForReenable(timeout: 2), "macOS never reported the timeout")
            sink.clear()

            // After recovery the tap intercepts again.
            Injector.click(number: 3)
            Injector.click(number: 9)
            #expect(sink.wait(timeout: 4) { Self.count($0, button: 9) == 2 })
            engine.drainCommands()
            print("[system] reenables=\(backend.reenables) nudges=\(nudges) state=\(engine.state)")
            print("[system] commands=\(executor.commands)")
            #expect(Self.count(sink.all, button: 3) == 0)
            #expect(executor.commands == [.perform(.customShortcut(Self.f19))])
            #expect(engine.state == EventTapState.active)
        }
    }
}
