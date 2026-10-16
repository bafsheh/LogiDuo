import LogiDuoDomain
import Testing

@Suite("HorizontalScrollAccumulator")
struct HorizontalScrollAccumulatorTests {
    private static let cooldown = HorizontalScrollAccumulator.actionCooldown

    /// Feeds a sequence of `(direction, delta, time)` events and returns which ones fired.
    private static func run(
        _ accumulator: inout HorizontalScrollAccumulator,
        _ events: [(HorizontalScrollDirection, Double?, Duration)]
    ) -> [Bool] {
        events.map { direction, delta, time in
            accumulator.feed(direction, delta: delta, cooldown: cooldown, at: time)
        }
    }

    @Test("fires once the accumulated magnitude reaches the threshold")
    func accumulates() {
        var accumulator = HorizontalScrollAccumulator(threshold: 0.3)
        let fired = Self.run(
            &accumulator,
            [(.left, 0.1, .seconds(1)), (.left, -0.1, .seconds(1)), (.left, 0.1, .seconds(1))]
        )
        #expect(fired == [false, false, true])
    }

    @Test("large deltas and unknown deltas count as one step")
    func clampsStep() {
        var accumulator = HorizontalScrollAccumulator(threshold: 1)
        #expect(Self.run(&accumulator, [(.right, 37, .seconds(1)), (.left, nil, .seconds(1))]) == [true, true])
        var higher = HorizontalScrollAccumulator(threshold: 1.5)
        #expect(Self.run(&higher, [(.left, 99, .seconds(1))]) == [false])
    }

    @Test("events during the cooldown are dropped and reset the accumulation")
    func cooldownResets() {
        var accumulator = HorizontalScrollAccumulator(threshold: 0.2)
        let start = Duration.seconds(1)
        let fired = Self.run(
            &accumulator,
            [
                (.left, 0.2, start),
                (.left, 1, start + .milliseconds(349)),
                (.left, 0.1, start + .milliseconds(350)),
                (.left, 0.1, start + .milliseconds(360)),
            ]
        )
        #expect(fired == [true, false, false, true])
    }

    @Test("directions accumulate and cool down independently")
    func independentDirections() {
        var accumulator = HorizontalScrollAccumulator(threshold: 0.2)
        #expect(Self.run(&accumulator, [(.left, 0.2, .seconds(1)), (.right, 0.2, .seconds(1))]) == [true, true])
    }

    @Test("volume actions use the short cooldown")
    func cooldowns() {
        #expect(HorizontalScrollAccumulator.cooldown(for: .media(.volumeUp)) == .milliseconds(60))
        #expect(HorizontalScrollAccumulator.cooldown(for: .media(.volumeDown)) == .milliseconds(60))
        #expect(HorizontalScrollAccumulator.cooldown(for: .media(.mute)) == .milliseconds(350))
        #expect(HorizontalScrollAccumulator.cooldown(for: .system(.nextSpace)) == .milliseconds(350))
    }

    @Test("the threshold is at least 0.01")
    func thresholdFloor() {
        #expect(HorizontalScrollAccumulator(threshold: 0).threshold == 0.01)
        #expect(HorizontalScrollAccumulator().threshold == 0.1)
    }
}
