import CoreGraphics
import Foundation
import Testing

/// Whether a person is at the Mac to press physical buttons.
let physicalTestsEnabled = ProcessInfo.processInfo.environment["LOGIDUO_PHYSICAL"] == "1"

/// A listen-only tap: it can observe but never modify or suppress events.
final class ListenOnlyObserver: @unchecked Sendable {  // Invariant: `seen` guarded by `lock`.
    private let lock = NSLock()
    private var seen: [Int64: Int] = [:]
    private var leftRight = 0
    private let tap = TailTap(listenOnly: true)

    /// Counts of physical (unmarked) presses per button number.
    var presses: [Int64: Int] { lock.withLock { seen } }

    /// Physical primary and secondary presses observed (proves they still reach the system).
    var primaryAndSecondary: Int { lock.withLock { leftRight } }

    func start() -> Bool {
        tap.install { [weak self] type, event in
            guard event.getIntegerValueField(.eventSourceUserData) == 0 else { return event }
            self?.lock.withLock {
                switch type {
                case .otherMouseDown: self?.seen[event.getIntegerValueField(.mouseEventButtonNumber), default: 0] += 1
                case .leftMouseDown, .rightMouseDown: self?.leftRight += 1
                default: break
                }
            }
            return event
        }
    }

    func stop() { tap.remove() }
}

@Suite(
    "Physical: button observation (listen-only, needs a person)",
    .enabled(if: physicalTestsEnabled),
    .timeLimit(.minutes(2))
)
struct PhysicalObservationTests {
    @Test("reports which button numbers the physical mouse produces")
    func observeButtons() async throws {
        let seconds = Int(ProcessInfo.processInfo.environment["LOGIDUO_PHYSICAL_SECONDS"] ?? "") ?? 20
        let observer = ListenOnlyObserver()
        try #require(observer.start())
        defer { observer.stop() }
        print(
            "[physical] Press middle, back and forward on the MX Master 3S, and left/right click, within \(seconds) s."
        )
        try await ContinuousClock().sleep(for: .seconds(seconds))
        print("[physical] other-button presses by number: \(observer.presses.sorted { $0.key < $1.key })")
        print("[physical] left/right presses observed: \(observer.primaryAndSecondary)")
        #expect(!observer.presses.isEmpty, "no physical presses observed")
    }
}
