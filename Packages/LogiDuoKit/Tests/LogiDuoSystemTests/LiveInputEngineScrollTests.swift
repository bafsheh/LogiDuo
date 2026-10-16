import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoSystem
import Testing

@Suite("LiveInputEngine scroll preferences (fake tap)", .serialized, .timeLimit(.minutes(1)))
struct LiveInputEngineScrollTests {
    private static func wheel(vertical: Int32, horizontal: Int32 = 0, shift: Bool = false) -> CGEvent {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
            )
        else { preconditionFailure("CGEvent creation") }
        if shift { event.flags.insert(.maskShift) }
        return event
    }

    private static func started(_ settings: ScrollSettings) -> (LiveInputEngine, FakeEventTapBackend) {
        let backend = FakeEventTapBackend()
        let engine = LiveInputEngine(backend: backend, executor: RecordingExecutor())
        engine.updateScrollSettings(settings)
        engine.start()
        return (engine, backend)
    }

    @Test("vertical inversion rewrites the delivered wheel event")
    func invertsVertical() throws {
        var settings = ScrollSettings.standard
        settings.invertVertical = true
        let (engine, backend) = Self.started(settings)
        defer { engine.stop() }

        let delivered = try #require(backend.deliver(.scrollWheel, Self.wheel(vertical: 3)))

        #expect(delivered.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3)
        #expect(delivered.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -3)
    }

    @Test("native settings deliver the wheel event unchanged")
    func unchanged() throws {
        let (engine, backend) = Self.started(.standard)
        defer { engine.stop() }
        let delivered = try #require(backend.deliver(.scrollWheel, Self.wheel(vertical: 2)))
        #expect(delivered.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 2)
    }

    @Test("Shift moves vertical wheel scrolling to the horizontal axis")
    func shiftHorizontal() throws {
        var settings = ScrollSettings.standard
        settings.shiftScrollsHorizontally = true
        let (engine, backend) = Self.started(settings)
        defer { engine.stop() }

        let delivered = try #require(backend.deliver(.scrollWheel, Self.wheel(vertical: 2, shift: true)))

        #expect(delivered.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(delivered.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 2)
    }

    @Test("trackpad gesture scrolling is never inverted by default")
    func trackpad() throws {
        var settings = ScrollSettings.standard
        settings.invertVertical = true
        let (engine, backend) = Self.started(settings)
        defer { engine.stop() }
        let gesture = Self.wheel(vertical: 4)
        gesture.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)

        let delivered = try #require(backend.deliver(.scrollWheel, gesture))

        #expect(delivered.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 4)
    }

    @Test("LogiDuo's own synthetic scroll events are never rewritten")
    func synthetic() throws {
        var settings = ScrollSettings.standard
        settings.invertVertical = true
        let (engine, backend) = Self.started(settings)
        defer { engine.stop() }
        let own = Self.wheel(vertical: 1)
        own.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)

        let delivered = try #require(backend.deliver(.scrollWheel, own))

        #expect(delivered.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 1)
    }
}

@Suite("LiveInputEngine device input (fake tap)", .serialized, .timeLimit(.minutes(1)))
struct LiveInputEngineDeviceInputTests {
    private static func engine() -> (LiveInputEngine, RecordingExecutor) {
        guard let set = try? MappingSet([ButtonMapping(trigger: .press(.forward), action: .click(.middle))]) else {
            preconditionFailure("valid")
        }
        let executor = RecordingExecutor()
        let engine = LiveInputEngine(
            backend: FakeEventTapBackend(),
            executor: executor,
            mappings: MappingResolver.resolve(set, capabilities: .undiscovered, mode: .enabled)
        )
        return (engine, executor)
    }

    @Test("device-reported presses are interpreted like tapped ones while active")
    func active() {
        let (engine, executor) = Self.engine()
        engine.start()
        defer { engine.stop() }
        engine.deviceInput(.buttonDown(.forward))
        engine.deviceInput(.buttonUp(.forward))
        engine.drainCommands()
        #expect(executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
    }

    @Test("device-reported input is ignored while interception is off")
    func inactive() {
        let (engine, executor) = Self.engine()
        engine.deviceInput(.buttonDown(.forward))
        engine.drainCommands()
        #expect(executor.commands.isEmpty)
    }
}
