import LogiDuoDomain
import Testing

@Suite("InputInterpreter")
struct InputInterpreterTests {
    private static let capabilities: MouseCapabilities = {
        guard let gestures = GestureCapability(buttons: [.gesture], supportsDirectionalSwipes: true) else {
            preconditionFailure("valid fixture")
        }
        return MouseCapabilities(divertableButtons: .supported([.gesture, .thumb]), gestures: .supported(gestures))
    }()

    private static func resolved(_ mappings: ButtonMapping...) -> ResolvedMappings {
        guard let set = try? MappingSet(mappings) else { preconditionFailure("valid fixture") }
        return MappingResolver.resolve(set, capabilities: capabilities, mode: .enabled)
    }

    private static let standard = resolved(
        ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)),
        ButtonMapping(trigger: .press(.forward), action: .click(.middle)),
        ButtonMapping(trigger: .press(.gesture), action: .system(.appExpose)),
        ButtonMapping(trigger: .swipe(.gesture, .left), action: .system(.previousSpace)),
        ButtonMapping(trigger: .swipe(.middle, .up), action: .system(.missionControl)),
        ButtonMapping(trigger: .horizontalScroll(.left), action: .media(.volumeDown))
    )

    private static func ms(_ value: Int) -> Duration { .milliseconds(value) }

    @Test("primary and secondary always pass through, whatever happens", arguments: [MouseButton.primary, .secondary])
    func protectedButtons(button: MouseButton) {
        var interpreter = InputInterpreter(mappings: Self.standard)
        #expect(
            interpreter.handle(.buttonDown(button), at: .zero) == InputResponse(disposition: .passThrough, commands: [])
        )
        _ = interpreter.cancelAll(at: .zero)
        #expect(interpreter.handle(.buttonUp(button), at: .zero).disposition == .passThrough)
    }

    @Test("unmapped buttons, orphan ups and plain motion pass through")
    func nativePassThrough() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        #expect(interpreter.handle(.buttonDown(.thumb), at: .zero).disposition == .passThrough)
        #expect(interpreter.handle(.buttonUp(.thumb), at: .zero).disposition == .passThrough)
        #expect(interpreter.handle(.buttonUp(.back), at: .zero).disposition == .passThrough)
        #expect(interpreter.handle(.motion(dx: 5, dy: 0, source: .eventTap), at: .zero).disposition == .passThrough)
        #expect(interpreter.handle(.horizontalScroll(.right, delta: 1), at: .zero).disposition == .passThrough)
    }

    @Test("a one-shot action fires on the down and its up is suppressed")
    func oneShot() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        #expect(interpreter.handle(.buttonDown(.back), at: .zero).commands == [.perform(.shortcut(.browserBack))])
        #expect(
            interpreter.handle(.buttonUp(.back), at: Self.ms(80)) == InputResponse(disposition: .suppress, commands: [])
        )
    }

    @Test("a click mapping mirrors down and up with a synthetic press")
    func clickMapping() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        #expect(interpreter.handle(.buttonDown(.forward), at: .zero).commands == [.pressSynthetic(.middle)])
        #expect(interpreter.handle(.buttonUp(.forward), at: Self.ms(50)).commands == [.releaseSynthetic(.middle)])
    }

    @Test("a swipe fires its action, freezes the cursor and suppresses the tap")
    func swipe() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        #expect(
            interpreter.handle(.buttonDown(.gesture), at: .zero) == InputResponse(disposition: .suppress, commands: [])
        )
        var commands: [InputCommand] = []
        for step in 1...7 {
            let response = interpreter.handle(.motion(dx: -10, dy: 0, source: .deviceRawXY), at: Self.ms(12 * step))
            #expect(response.disposition == .suppress)
            commands += response.commands
        }
        #expect(commands == [.perform(.system(.previousSpace))])
        #expect(interpreter.handle(.buttonUp(.gesture), at: Self.ms(100)).commands.isEmpty)
    }

    @Test("a tap on a swipe button runs the press action")
    func tapRunsPressAction() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        _ = interpreter.handle(.buttonDown(.gesture), at: .zero)
        #expect(interpreter.handle(.buttonUp(.gesture), at: Self.ms(90)).commands == [.perform(.system(.appExpose))])
    }

    @Test("a tap on a swipe button without a press action replays the native click")
    func tapReplaysNativeClick() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        _ = interpreter.handle(.buttonDown(.middle), at: .zero)
        let response = interpreter.handle(.buttonUp(.middle), at: Self.ms(90))
        #expect(response == InputResponse(disposition: .suppress, commands: [.replayNativeClick(.middle)]))
    }

    @Test("a swipe in an unmapped direction is absorbed without a tap")
    func unmappedSwipeDirection() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        _ = interpreter.handle(.buttonDown(.gesture), at: .zero)
        var commands: [InputCommand] = []
        for step in 1...7 {
            commands +=
                interpreter.handle(.motion(dx: 10, dy: 0, source: .deviceRawXY), at: Self.ms(12 * step)).commands
        }
        commands += interpreter.handle(.buttonUp(.gesture), at: Self.ms(100)).commands
        #expect(commands.isEmpty)
    }

    @Test("regression: switching profiles mid-press releases the synthetic press once and suppresses the up")
    func profileSwitchMidPress() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        _ = interpreter.handle(.buttonDown(.forward), at: .zero)

        #expect(interpreter.updateMappings(.passThrough) == [.releaseSynthetic(.middle)])
        #expect(
            interpreter.handle(.buttonUp(.forward), at: Self.ms(30))
                == InputResponse(disposition: .suppress, commands: [])
        )
        #expect(interpreter.handle(.buttonDown(.forward), at: Self.ms(60)).disposition == .passThrough)
    }

    @Test("a down passed through before a profile switch keeps its up native")
    func passThroughPairing() {
        var interpreter = InputInterpreter(mappings: .passThrough)
        _ = interpreter.handle(.buttonDown(.back), at: .zero)
        _ = interpreter.updateMappings(Self.standard)
        #expect(interpreter.handle(.buttonUp(.back), at: Self.ms(30)).disposition == .passThrough)
    }

    @Test("cancelling releases synthetic presses, drops gestures without a tap and suppresses the pending ups")
    func cancelAll() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        _ = interpreter.handle(.buttonDown(.forward), at: .zero)
        _ = interpreter.handle(.buttonDown(.gesture), at: .zero)

        #expect(interpreter.cancelAll(at: Self.ms(10)) == [.releaseSynthetic(.middle)])
        #expect(
            interpreter.handle(.buttonUp(.gesture), at: Self.ms(20))
                == InputResponse(disposition: .suppress, commands: [])
        )
        #expect(interpreter.handle(.buttonUp(.forward), at: Self.ms(20)).commands.isEmpty)
        #expect(
            interpreter.handle(.motion(dx: 3, dy: 3, source: .eventTap), at: Self.ms(30)).disposition == .passThrough
        )
    }

    @Test("a synthetic press without a physical up is released after 20 seconds, exactly once")
    func staleSyntheticPress() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        _ = interpreter.handle(.buttonDown(.forward), at: .zero)

        #expect(interpreter.expireStalePresses(at: .seconds(19)).isEmpty)
        #expect(interpreter.expireStalePresses(at: .seconds(20)) == [.releaseSynthetic(.middle)])
        #expect(interpreter.expireStalePresses(at: .seconds(40)).isEmpty)
        #expect(interpreter.handle(.buttonUp(.forward), at: .seconds(41)).commands.isEmpty)
    }

    @Test("a repeated down without an up neither fires twice nor changes the pairing")
    func repeatedDown() {
        var interpreter = InputInterpreter(mappings: Self.standard)
        _ = interpreter.handle(.buttonDown(.back), at: .zero)
        #expect(
            interpreter.handle(.buttonDown(.back), at: Self.ms(5))
                == InputResponse(disposition: .suppress, commands: [])
        )
        _ = interpreter.handle(.buttonDown(.thumb), at: .zero)
        #expect(interpreter.handle(.buttonDown(.thumb), at: Self.ms(5)).disposition == .passThrough)
    }

    @Test("mapped horizontal scrolling is suppressed and fires at the threshold with its cooldown")
    func horizontalScroll() {
        var interpreter = InputInterpreter(mappings: Self.standard, scrollThreshold: 0.2)
        let first = interpreter.handle(.horizontalScroll(.left, delta: 0.1), at: .seconds(1))
        let second = interpreter.handle(.horizontalScroll(.left, delta: 0.1), at: .seconds(1))
        let cooling = interpreter.handle(.horizontalScroll(.left, delta: 1), at: .seconds(1) + Self.ms(30))
        #expect(first == InputResponse(disposition: .suppress, commands: []))
        #expect(second.commands == [.perform(.media(.volumeDown))])
        #expect(cooling == InputResponse(disposition: .suppress, commands: []))
    }

    @Test("disabled remapping passes everything through")
    func disabledRemapping() {
        var interpreter = InputInterpreter(mappings: .passThrough)
        for event in [
            InputEvent.buttonDown(.back), .buttonUp(.back), .buttonDown(.gesture),
            .motion(dx: -40, dy: 0, source: .eventTap),
            .buttonUp(.gesture), .horizontalScroll(.left, delta: 1),
        ] {
            #expect(interpreter.handle(event, at: .zero).disposition == .passThrough)
        }
    }

    @Test("overlapping holders of one synthetic button produce one press and one release")
    func overlappingSyntheticPresses() {
        let mappings = Self.resolved(
            ButtonMapping(trigger: .press(.forward), action: .click(.middle)),
            ButtonMapping(trigger: .press(.back), action: .click(.middle)),
            ButtonMapping(trigger: .press(.thumb), action: .click(.middle))
        )
        var interpreter = InputInterpreter(mappings: mappings)
        var commands = interpreter.handle(.buttonDown(.forward), at: .zero).commands
        commands += interpreter.handle(.buttonDown(.back), at: .zero).commands
        commands += interpreter.handle(.buttonUp(.forward), at: Self.ms(10)).commands
        #expect(commands == [.pressSynthetic(.middle)])
        #expect(interpreter.handle(.buttonUp(.back), at: Self.ms(20)).commands == [.releaseSynthetic(.middle)])
    }

    @Test("randomized sequences keep synthetic presses balanced and never release twice")
    func randomizedBalance() {
        var random = SplitMix64(seed: 0x1D0_0D0E)
        var interpreter = InputInterpreter(mappings: Self.standard)
        var ledger = SyntheticLedger()
        var time = Duration.zero
        for _ in 0..<20_000 {
            time += .milliseconds(Int(random.next() % 40))
            ledger.record(Self.randomStep(&interpreter, &random, at: time))
        }
        ledger.record(interpreter.cancelAll(at: time))
        #expect(ledger.violations.isEmpty)
        #expect(ledger.held.isEmpty)
    }

    private static let overlapping = resolved(
        ButtonMapping(trigger: .press(.forward), action: .click(.middle)),
        ButtonMapping(trigger: .press(.back), action: .click(.middle)),
        ButtonMapping(trigger: .press(.gesture), action: .click(.middle)),
        ButtonMapping(trigger: .swipe(.gesture, .left), action: .click(.middle)),
        ButtonMapping(trigger: .swipe(.middle, .up), action: .click(.back))
    )

    /// Applies one random event or lifecycle operation and returns its commands.
    private static func randomStep(
        _ interpreter: inout InputInterpreter,
        _ random: inout SplitMix64,
        at time: Duration
    ) -> [InputCommand] {
        let buttons: [MouseButton] = [.primary, .back, .forward, .gesture, .middle, .thumb]
        let button = buttons[Int(random.next() % 6)]
        switch random.next() % 100 {
        case 0..<35: return interpreter.handle(.buttonDown(button), at: time).commands
        case 35..<70: return interpreter.handle(.buttonUp(button), at: time).commands
        case 70..<90:
            let dx = Double(Int(random.next() % 41) - 20)
            return interpreter.handle(.motion(dx: dx, dy: 0, source: .deviceRawXY), at: time).commands
        case 90..<94:
            return interpreter.updateMappings(
                [ResolvedMappings.passThrough, standard, overlapping][Int(random.next() % 3)]
            )
        case 94..<97: return interpreter.cancelAll(at: time)
        default: return interpreter.expireStalePresses(at: time)
        }
    }
}

/// Tracks synthetic presses and records any unbalanced command.
struct SyntheticLedger {
    private(set) var held: Set<SyntheticButton> = []
    private(set) var violations: [String] = []

    mutating func record(_ commands: [InputCommand]) {
        for command in commands {
            switch command {
            case .pressSynthetic(let button):
                if !held.insert(button).inserted { violations.append("press while pressed: \(button)") }
            case .releaseSynthetic(let button):
                if held.remove(button) == nil { violations.append("release without press: \(button)") }
            default:
                break
            }
        }
    }
}

/// A small deterministic generator for reproducible randomized tests.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
