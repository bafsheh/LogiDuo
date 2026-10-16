import CoreGraphics
import Foundation
import LogiDuoDomain

/// Where a button press came from, judged from fields the poster cannot hide.
enum PressOrigin: String, CaseIterable, Sendable {
    /// From the hardware: no marker and no posting process.
    case physical
    /// Posted by LogiDuo (its marker).
    case logiDuo
    /// Posted by some other process (this includes system-test injections).
    case otherSynthetic

    /// Hardware events carry no source process; every posted event carries its poster's.
    static func of(userData: Int64, sourceProcess: Int64) -> PressOrigin {
        if SyntheticEventMarker.isLogiDuoEvent(userData: userData) { return .logiDuo }
        return userData == 0 && sourceProcess == 0 ? .physical : .otherSynthetic
    }
}

/// Where in the event pipeline a press was seen.
enum EvidenceStage: String, CaseIterable, Sendable {
    /// At the HID level, before LogiDuo's session tap: what the person pressed.
    case pressed
    /// After every session tap: what reached applications.
    case delivered
}

/// Press counts per stage, origin and button number (0 left, 1 right, 2 middle, 3 back, 4 forward).
struct PressEvidence: Sendable {
    private(set) var counts: [EvidenceStage: [PressOrigin: [Int64: Int]]] = [:]
    private(set) var sourceProcesses: Set<Int64> = []

    mutating func record(stage: EvidenceStage, button: Int64, userData: Int64, sourceProcess: Int64) {
        counts[stage, default: [:]][PressOrigin.of(userData: userData, sourceProcess: sourceProcess), default: [:]][
            button,
            default: 0
        ] += 1
        sourceProcesses.insert(sourceProcess)
    }

    func count(_ stage: EvidenceStage, _ origin: PressOrigin, button: Int64) -> Int {
        counts[stage]?[origin]?[button] ?? 0
    }

    /// One `[evidence] stage=… origin=… button=… count=…` line per non-zero count, for scripts.
    var lines: [String] {
        EvidenceStage.allCases.flatMap { stage in
            PressOrigin.allCases.flatMap { origin in
                (counts[stage]?[origin] ?? [:]).sorted { $0.key < $1.key }.map { button, count in
                    "[evidence] stage=\(stage.rawValue) origin=\(origin.rawValue) button=\(button) count=\(count)"
                }
            }
        }
    }
}

/// Two listen-only taps: one at the HID level (before LogiDuo) and one after every session tap.
/// Listen-only taps are told about events asynchronously, so readers wait rather than read once.
final class PhysicalEvidenceObserver: @unchecked Sendable {  // Invariant: `evidence` guarded by `lock`.
    private let lock = NSCondition()
    private var evidence = PressEvidence()
    private let pressedTap = TailTap(listenOnly: true, location: .cghidEventTap, place: .headInsertEventTap)
    private let deliveredTap = TailTap(listenOnly: true)

    static let downTypes: Set<CGEventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    var snapshot: PressEvidence { lock.withLock { evidence } }

    /// Waits until `predicate` holds for the evidence; `timeout` only bounds a failing wait.
    func wait(timeout: TimeInterval = 2, until predicate: (PressEvidence) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        defer { lock.unlock() }
        while !predicate(evidence) {
            guard lock.wait(until: deadline) else { return predicate(evidence) }
        }
        return true
    }

    /// Starts both taps; `false` (with nothing left running) if either could not be created.
    func start() -> Bool {
        guard pressedTap.install({ [weak self] type, event in self?.observe(.pressed, type, event) ?? event }) else {
            return false
        }
        guard deliveredTap.install({ [weak self] type, event in self?.observe(.delivered, type, event) ?? event })
        else {
            pressedTap.remove()
            return false
        }
        return true
    }

    func stop() {
        deliveredTap.remove()
        pressedTap.remove()
    }

    private func observe(_ stage: EvidenceStage, _ type: CGEventType, _ event: CGEvent) -> CGEvent {
        guard Self.downTypes.contains(type) else { return event }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let userData = event.getIntegerValueField(.eventSourceUserData)
        let process = event.getIntegerValueField(.eventSourceUnixProcessID)
        lock.withLock {
            evidence.record(stage: stage, button: button, userData: userData, sourceProcess: process)
            lock.broadcast()
        }
        return event
    }
}
