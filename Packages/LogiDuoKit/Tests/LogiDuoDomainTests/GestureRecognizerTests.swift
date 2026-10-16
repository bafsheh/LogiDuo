import LogiDuoDomain
import Testing

/// Ports `tests/test_gesture_recognizer.py` (Mouser) with identical sequences and timing.
@Suite("GestureRecognizer")
struct GestureRecognizerTests {
    /// Mouser's test fixture: threshold 50, 400 ms window, 90 ms settle, cross ratio 0.5.
    private static let mouserTest = GestureConfiguration(threshold: 50)

    private struct Harness {
        var recognizer: GestureRecognizer
        var time: Duration = .zero
        var swipes: [SwipeDirection] = []

        init(enabled: Bool = true) {
            recognizer = GestureRecognizer(configuration: GestureRecognizerTests.mouserTest, isEnabled: enabled)
        }

        /// Feeds `deltas` 12 ms apart; `gap` replaces the first interval.
        mutating func feed(
            _ deltas: [(Double, Double)],
            gap: Duration? = nil,
            source: MotionSource = .deviceRawXY
        ) {
            for (offset, delta) in deltas.enumerated() {
                time += offset == 0 ? (gap ?? .milliseconds(12)) : .milliseconds(12)
                if let swipe = recognizer.sample(dx: delta.0, dy: delta.1, source: source, at: time) {
                    swipes.append(swipe)
                }
            }
        }
    }

    private static func repeated(_ delta: (Double, Double), _ count: Int) -> [(Double, Double)] {
        Array(repeating: delta, count: count)
    }

    private static let flickLeft = repeated((-10, 0), 7)
    private static let flickRight = repeated((10, 0), 7)

    @Test("a single left swipe fires once and is not a tap")
    func singleLeft() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.flickLeft)
        #expect(harness.recognizer.end() == .swiped([.left]))
        #expect(harness.swipes == [.left])
    }

    @Test(
        "each direction is recognised",
        arguments: [
            ((-10.0, 0.0), SwipeDirection.left), ((10, 0), .right), ((0, -10), .up), ((0, 10), .down),
        ]
    )
    func directions(delta: (Double, Double), expected: SwipeDirection) {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.repeated(delta, 7))
        _ = harness.recognizer.end()
        #expect(harness.swipes == [expected])
    }

    @Test("one long continuous motion fires only once")
    func longMotion() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.repeated((-10, 0), 40))
        #expect(harness.swipes == [.left])
    }

    @Test(
        "false positives are rejected",
        arguments: [
            ("slow drift", repeated((-1, 0), 70)),
            ("below threshold", repeated((-6, 0), 5)),
            ("steep diagonal", repeated((-9, -9), 8)),
        ]
    )
    func falsePositives(name: String, deltas: [(Double, Double)]) {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(deltas)
        _ = harness.recognizer.end()
        #expect(harness.swipes.isEmpty, "\(name)")
    }

    @Test("a mild diagonal resolves to the dominant axis")
    func mildDiagonal() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.repeated((-10, -3), 7))
        #expect(harness.swipes == [.left])
    }

    @Test("repeated flicks in one hold each fire; return strokes do not")
    func repeatedFlicks() {
        var harness = Harness()
        harness.recognizer.begin()
        for stroke in [Self.flickLeft, Self.flickRight, Self.flickLeft, Self.flickRight, Self.flickLeft] {
            harness.feed(stroke)
        }
        #expect(harness.swipes == [.left, .left, .left])
    }

    @Test("a return stroke alone never fires the opposite direction")
    func returnStroke() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.flickLeft)
        harness.feed(Self.repeated((12, 0), 9))
        #expect(harness.swipes == [.left])
    }

    @Test("flicks across separate holds each fire")
    func separateHolds() {
        var harness = Harness()
        for _ in 0..<4 {
            harness.recognizer.begin()
            harness.feed(Self.flickLeft)
            #expect(harness.recognizer.end() != .tap)
            harness.time += .milliseconds(30)
        }
        #expect(harness.swipes == [.left, .left, .left, .left])
    }

    @Test("the direction can change after a pause")
    func pauseUnlocks() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.flickLeft)
        harness.feed(Self.flickRight, gap: .milliseconds(200))
        #expect(harness.swipes == [.left, .right])
    }

    @Test("an opposite flick within a locked hold is absorbed")
    func oppositeAbsorbed() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.flickLeft)
        harness.feed(Self.flickRight)
        #expect(harness.swipes == [.left])
    }

    @Test("press and release without motion, or with tiny motion, is a tap")
    func taps() {
        var still = Harness()
        still.recognizer.begin()
        #expect(still.recognizer.end() == .tap)

        var tiny = Harness()
        tiny.recognizer.begin()
        tiny.feed(Self.repeated((-3, 0), 3))
        #expect(tiny.recognizer.end() == .tap)
    }

    @Test("a disabled recognizer emits nothing and every hold is a tap")
    func disabled() {
        var harness = Harness(enabled: false)
        harness.recognizer.begin()
        harness.feed(Self.flickLeft)
        #expect(harness.recognizer.end() == .tap)
        #expect(harness.swipes.isEmpty)
    }

    @Test("device raw XY supersedes event-tap motion, which is then ignored")
    func sourcePriority() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.repeated((-10, 0), 4), source: .eventTap)
        harness.feed(Self.flickLeft, source: .deviceRawXY)
        harness.feed([(-40, 0)], source: .eventTap)
        #expect(harness.swipes == [.left])
    }

    @Test(
        "click jolts do not fire; a quick flick with enough reports does",
        arguments: [
            ([(-34.0, 0.0), (-34, 0)], [SwipeDirection]()),
            ([(-95, 5)], []),
            (repeated((-14, 0), 5), [.left]),
        ]
    )
    func jolts(deltas: [(Double, Double)], expected: [SwipeDirection]) {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(deltas)
        _ = harness.recognizer.end()
        #expect(harness.swipes == expected)
    }

    // MARK: - LogiDuo additions

    @Test("cancelling a hold yields no tap and ignores later motion")
    func cancellation() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.repeated((-10, 0), 3))
        harness.recognizer.cancel()
        harness.feed(Self.flickLeft)
        #expect(harness.recognizer.end() == .none)
        #expect(harness.swipes.isEmpty)
    }

    @Test("motion outside a hold is ignored and ending without a hold is nothing")
    func inactive() {
        var harness = Harness()
        harness.feed(Self.flickLeft)
        #expect(harness.swipes.isEmpty)
        #expect(harness.recognizer.end() == .none)
    }

    @Test("begin discards the previous hold's swipes")
    func beginResets() {
        var harness = Harness()
        harness.recognizer.begin()
        harness.feed(Self.flickLeft)
        _ = harness.recognizer.end()
        harness.recognizer.begin()
        #expect(harness.recognizer.fired.isEmpty)
        #expect(harness.recognizer.end() == .tap)
    }

    @Test("configuration values are clamped like Mouser's")
    func clamping() {
        let low = GestureConfiguration(threshold: 1, commitWindow: .milliseconds(1), settle: .zero, crossRatio: 0)
        #expect(low.commitDistance == 8 && low.commitWindow == .milliseconds(50) && low.settle == .milliseconds(20))
        #expect(low.crossRatio == 0.05 && low.directionEpsilon == 5 && low.minimumReturn == 14)
        let high = GestureConfiguration(threshold: 100, crossRatio: 9)
        #expect(high.crossRatio == 2 && high.directionEpsilon == 15 && high.minimumReturn == 45)
        #expect(GestureConfiguration.standard.commitDistance == 25)
    }
}
