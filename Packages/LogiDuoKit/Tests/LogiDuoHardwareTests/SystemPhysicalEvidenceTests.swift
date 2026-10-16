import CoreGraphics
import Foundation
import Testing

extension LiveSystemSuites {
    @Suite("System: physical evidence never counts posted events", .timeLimit(.minutes(1)))
    struct SystemPhysicalEvidenceTests {
        @Test("an injected press is seen at both stages and classified as synthetic, never physical")
        func injectedIsNotPhysical() throws {
            let observer = PhysicalEvidenceObserver()
            try #require(observer.start())
            defer { observer.stop() }
            // Installed after the observer, so the sink's tail tap runs later and swallows the press before apps.
            let sink = EventSink()
            try #require(sink.start())
            defer { sink.stop() }

            Injector.click(number: 3)
            #expect(sink.wait { $0.contains { $0.button == 3 } })

            #expect(
                observer.wait { seen in
                    seen.count(.pressed, .otherSynthetic, button: 3) == 1
                        && seen.count(.delivered, .otherSynthetic, button: 3) == 1
                }
            )
            let evidence = observer.snapshot
            print("[evidence] injected press: \(evidence.lines) processes \(evidence.sourceProcesses.sorted())")
            #expect(evidence.count(.pressed, .otherSynthetic, button: 3) == 1)
            #expect(evidence.count(.delivered, .otherSynthetic, button: 3) == 1)
            #expect(evidence.count(.pressed, .physical, button: 3) == 0)
            #expect(evidence.count(.delivered, .physical, button: 3) == 0)
            #expect(!evidence.sourceProcesses.contains(0), "a posted event must carry its poster's process")
        }
    }
}
