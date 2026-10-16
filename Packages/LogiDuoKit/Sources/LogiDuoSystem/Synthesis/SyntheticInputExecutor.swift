import Foundation
public import LogiDuoDomain
import os

/// Posts one synthetic event. Abstracted so the executor is testable without posting.
public protocol SyntheticEventPosting: Sendable {
    /// Posts `spec`, marked as LogiDuo's own event.
    func post(_ spec: SyntheticEventSpec)
}

/// Performs input commands by posting synthetic events.
///
/// Safety: tracks which synthetic mouse buttons it has pressed; a release for a
/// button it did not press is dropped, a second press is dropped, and
/// ``releaseAllHeld()`` releases everything still down (used on shutdown as
/// a last line of defense after the interpreter's own releases).
public final class SyntheticInputExecutor: InputCommandPerforming, @unchecked Sendable {  // Invariant: `lock`.
    private let poster: any SyntheticEventPosting
    private let lock = NSLock()
    private var held: Set<SyntheticButton> = []
    private var gapCount = 0
    private let logger = Logger(subsystem: "io.github.bafsheh.LogiDuo", category: "SyntheticInput")

    /// Creates an executor posting through `poster`.
    public init(poster: any SyntheticEventPosting) {
        self.poster = poster
    }

    /// Synthetic buttons currently held down.
    public var heldButtons: Set<SyntheticButton> { lock.withLock { held } }

    /// Commands that could not be performed (see ``SyntheticPlanGap``).
    public var unperformedCommands: Int { lock.withLock { gapCount } }

    /// Performs `commands` in order.
    public func perform(_ commands: [InputCommand]) {
        for command in commands {
            let plan = SyntheticEventPlanner.plan(command)
            if let gap = plan.gap {
                lock.withLock { gapCount += 1 }
                logger.info("Not performed: \(String(describing: gap), privacy: .public)")
            }
            for event in plan.events where admit(event) {
                poster.post(event)
            }
        }
    }

    /// Releases every synthetic button still held.
    public func releaseAllHeld() {
        let buttons = lock.withLock {
            defer { held = [] }
            return held
        }
        for button in buttons.sorted(by: { $0.rawValue < $1.rawValue }) {
            poster.post(.mouseButton(button, isDown: false))
        }
    }

    /// Keeps mouse-button transitions balanced.
    private func admit(_ event: SyntheticEventSpec) -> Bool {
        guard case .mouseButton(let button, let isDown) = event else { return true }
        return lock.withLock {
            if isDown { return held.insert(button).inserted }
            return held.remove(button) != nil
        }
    }
}
