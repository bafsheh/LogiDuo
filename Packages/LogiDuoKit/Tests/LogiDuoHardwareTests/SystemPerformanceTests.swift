import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoSystem
import Testing

extension LiveSystemSuites {
    @Suite("System: input latency (measurement)", .timeLimit(.minutes(2)))
    struct SystemPerformanceTests {
        @Test("decision cost per event in the callback core")
        func decisionCost() throws {
            let set = try MappingSet([ButtonMapping(trigger: .press(.forward), action: .click(.middle))])
            let core = InputEngineCore(
                mappings: MappingResolver.resolve(set, capabilities: .undiscovered, mode: .enabled)
            )
            _ = core.signal(.startRequested, at: .zero)
            _ = core.signal(.tapInstalled, at: .zero)
            let down = TapEventSnapshot(kind: .otherMouseDown, buttonNumber: 4)
            let up = TapEventSnapshot(kind: .otherMouseUp, buttonNumber: 4)
            let motion = TapEventSnapshot(kind: .mouseMoved, deltaX: 3, deltaY: -1)
            let clock = ContinuousClock()
            let iterations = 200_000
            let started = clock.now
            for index in 0..<iterations {
                let time = Duration.microseconds(index)
                _ = core.decide(down, at: time)
                _ = core.decide(motion, at: time)
                _ = core.decide(up, at: time)
            }
            let perEvent = (clock.now - started) / (iterations * 3)
            print("[perf] InputEngineCore.decide: \(perEvent) per event over \(iterations * 3) events")
            #expect(perEvent < .microseconds(50))
        }

        @Test("end-to-end: injected mapped click to synthetic click reaching the end of the pipeline")
        func endToEnd() throws {
            let sink = EventSink()
            try #require(sink.start())
            defer { sink.stop() }
            Injector.click(number: 9)
            try #require(sink.wait { records in records.filter { $0.button == 9 }.count >= 2 })
            let set = try MappingSet([ButtonMapping(trigger: .press(.forward), action: .click(.middle))])
            let engine = LiveInputEngine(
                executor: SyntheticInputExecutor(poster: CoreGraphicsEventPoster()),
                mappings: MappingResolver.resolve(set, capabilities: .undiscovered, mode: .enabled)
            )
            engine.start()
            defer { engine.stop() }

            var samples: [Duration] = []
            let clock = ContinuousClock()
            for round in 1...200 {
                sink.clear()
                let started = clock.now
                Injector.button(.otherMouseDown, number: 4)
                guard sink.wait(until: { records in records.contains { $0.button == 2 } }) else { break }
                samples.append(clock.now - started)
                Injector.button(.otherMouseUp, number: 4)
                _ = sink.wait { records in records.filter { $0.button == 2 }.count >= 2 }
                _ = round
            }
            samples.sort()
            try #require(samples.count == 200)
            print("[perf] inject→synthetic delivery p50=\(samples[100]) p95=\(samples[190]) max=\(samples[199])")
            #expect(samples[190] < .milliseconds(20))
        }
    }
}
