import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoSystem
import Testing

extension LiveSystemSuites {
    @Suite("System: synthetic input (test-marked and LogiDuo-marked events only)", .timeLimit(.minutes(2)))
    struct SystemSynthesisTests {
        private static func mapping(_ mappings: ButtonMapping...) -> ResolvedMappings {
            guard let set = try? MappingSet(mappings) else { preconditionFailure("valid") }
            return MappingResolver.resolve(set, capabilities: .undiscovered, mode: .enabled)
        }

        private static func armedSink() throws -> EventSink {
            let sink = EventSink()
            try #require(sink.start(), "sink tap could not be created")
            Injector.click(number: 9)
            let armed = sink.wait { records in records.filter { $0.button == 9 }.count >= 2 }
            if !armed { sink.stop() }
            try #require(armed, "sink did not receive the probe; aborting")
            sink.clear()
            return sink
        }

        private static func synthetic(_ records: [SinkRecord], type: CGEventType, button: Int64) -> Int {
            records.filter { record in
                record.type == type.rawValue && record.button == button
                    && SyntheticEventMarker.isLogiDuoEvent(userData: record.userData)
            }
            .count
        }

        private static func engine(_ mappings: ResolvedMappings) -> (LiveInputEngine, SyntheticInputExecutor) {
            let executor = SyntheticInputExecutor(poster: CoreGraphicsEventPoster())
            return (LiveInputEngine(executor: executor, mappings: mappings), executor)
        }

        @Test("a click mapping produces one marked press and release that do not re-trigger the mapping")
        func clickWithoutRecursion() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            // Back → middle click, and middle → back click: a loop if synthetic events were re-interpreted.
            let (engine, executor) = Self.engine(
                Self.mapping(ButtonMapping(trigger: .press(.back), action: .click(.middle)))
            )
            engine.start()
            defer { engine.stop() }

            Injector.click(number: 3)
            #expect(sink.wait { Self.synthetic($0, type: .otherMouseUp, button: 2) == 1 })
            engine.drainCommands()
            #expect(Self.synthetic(sink.all, type: .otherMouseDown, button: 2) == 1)
            #expect(!sink.all.contains { $0.button == 3 })
            #expect(engine.statistics.syntheticSeen == 2)
            #expect(executor.heldButtons.isEmpty)
        }

        @Test("a shortcut mapping posts one marked key down and key up")
        func shortcut() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            guard let f19 = KeyCode(rawValue: 0x50).flatMap({ KeyboardShortcut(key: $0, modifiers: []) }) else {
                return
            }
            let (engine, _) = Self.engine(
                Self.mapping(ButtonMapping(trigger: .press(.forward), action: .customShortcut(f19)))
            )
            engine.start()
            defer { engine.stop() }

            Injector.click(number: 4)
            #expect(
                sink.wait { records in records.contains { $0.type == CGEventType.keyUp.rawValue && $0.keyCode == 0x50 }
                }
            )
            let keys = sink.all.filter { record in
                record.keyCode == 0x50 && SyntheticEventMarker.isLogiDuoEvent(userData: record.userData)
            }
            #expect(keys.map(\.type) == [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue])
        }

        @Test("rapid input: 200 mapped clicks produce exactly 200 balanced synthetic clicks")
        func rapidInput() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            let (engine, executor) = Self.engine(
                Self.mapping(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
            )
            engine.start()
            defer { engine.stop() }

            for _ in 0..<200 { Injector.click(number: 4) }
            #expect(sink.wait(timeout: 10) { Self.synthetic($0, type: .otherMouseUp, button: 2) == 200 })
            engine.drainCommands()
            #expect(Self.synthetic(sink.all, type: .otherMouseDown, button: 2) == 200)
            #expect(executor.heldButtons.isEmpty)
        }

        @Test(
            "changing the profile during a held press releases the synthetic button once and swallows the physical up"
        )
        func profileChangeMidPress() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            let (engine, executor) = Self.engine(
                Self.mapping(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
            )
            engine.start()
            defer { engine.stop() }

            Injector.button(.otherMouseDown, number: 4)
            #expect(sink.wait { Self.synthetic($0, type: .otherMouseDown, button: 2) == 1 })
            engine.updateMappings(.passThrough)
            Injector.button(.otherMouseUp, number: 4)
            Injector.click(number: 9)
            #expect(sink.wait { records in records.filter { $0.button == 9 }.count == 2 })

            #expect(Self.synthetic(sink.all, type: .otherMouseUp, button: 2) == 1)
            #expect(!sink.all.contains { $0.button == 4 })
            #expect(executor.heldButtons.isEmpty)
        }

        @Test("stopping during a held press releases the synthetic button")
        func stopMidPress() throws {
            let sink = try Self.armedSink()
            defer { sink.stop() }
            let (engine, executor) = Self.engine(
                Self.mapping(ButtonMapping(trigger: .press(.forward), action: .click(.middle)))
            )
            engine.start()

            Injector.button(.otherMouseDown, number: 4)
            #expect(sink.wait { Self.synthetic($0, type: .otherMouseDown, button: 2) == 1 })
            engine.stop()

            #expect(sink.wait { Self.synthetic($0, type: .otherMouseUp, button: 2) == 1 })
            #expect(executor.heldButtons.isEmpty)
            Injector.button(.otherMouseUp, number: 4)
            #expect(
                sink.wait { records in
                    records.contains { $0.button == 4 && $0.type == CGEventType.otherMouseUp.rawValue }
                }
            )
        }
    }
}
