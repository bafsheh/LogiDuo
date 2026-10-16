import CoreGraphics
import Foundation
import Testing

/// Whether a person is at the Mac to press physical buttons.
let physicalTestsEnabled = ProcessInfo.processInfo.environment["LOGIDUO_PHYSICAL"] == "1"

@Suite(
    "Physical: button observation (listen-only, needs a person)",
    .enabled(if: physicalTestsEnabled),
    .timeLimit(.minutes(2))
)
struct PhysicalObservationTests {
    @Test("reports which presses the person made and which reached applications")
    func observeButtons() async throws {
        let seconds = Int(ProcessInfo.processInfo.environment["LOGIDUO_PHYSICAL_SECONDS"] ?? "") ?? 20
        let observer = PhysicalEvidenceObserver()
        try #require(observer.start(), "the listen-only taps could not be created (Input Monitoring?)")
        defer { observer.stop() }
        print("[physical] GO: press the buttons now, within \(seconds) s.")
        try await ContinuousClock().sleep(for: .seconds(seconds))
        let evidence = observer.snapshot
        print("[physical] observation complete")
        for line in evidence.lines { print(line) }
        print("[physical] source processes seen: \(evidence.sourceProcesses.sorted())")
        // Report-only runs (guided validation) judge the evidence in the script.
        if ProcessInfo.processInfo.environment["LOGIDUO_PHYSICAL_REPORT_ONLY"] != "1" {
            #expect(evidence.lines.contains { $0.contains("origin=physical") }, "no physical presses observed")
        }
    }
}
