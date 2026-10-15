/// One trigger-to-action binding.
public struct ButtonMapping: Hashable, Sendable, Codable {
    /// The input that fires the mapping.
    public let trigger: InputTrigger
    /// What happens when it fires.
    public let action: Action
    /// A disabled mapping is kept but behaves as ``Action/passThrough``.
    public let isEnabled: Bool

    /// Creates a mapping.
    public init(trigger: InputTrigger, action: Action, isEnabled: Bool = true) {
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
    }

    /// The action that takes effect: the mapped action if enabled, otherwise pass-through.
    public var effectiveAction: Action { isEnabled ? action : .passThrough }
}

/// Why a mapping was rejected.
public enum MappingRejection: Error, Hashable, Sendable {
    /// The trigger involves a protected button (primary or secondary).
    case protectedTrigger(InputTrigger)
    /// More than one mapping uses the same trigger.
    case duplicateTrigger(InputTrigger)
    /// The mapping clicks the button that triggers it.
    case selfReferential(InputTrigger)
    /// Mappings click each other's buttons in a cycle, listed in trigger order.
    case clickCycle([MouseButton])
}

/// A coherent set of mappings with at most one mapping per trigger.
///
/// Construction enforces the safety invariants: protected buttons are never
/// triggers, and synthetic clicks can never feed back into their own trigger,
/// directly or through a cycle. Triggers without a mapping pass through.
public struct MappingSet: Hashable, Sendable {
    /// No mappings: every input behaves natively.
    public static let empty = MappingSet(validated: [:])

    /// The mappings, keyed by trigger.
    public let mappings: [InputTrigger: ButtonMapping]

    /// Creates a mapping set.
    /// - Throws: ``MappingRejection`` describing the first violated invariant.
    public init(_ mappings: [ButtonMapping]) throws(MappingRejection) {
        var byTrigger: [InputTrigger: ButtonMapping] = [:]
        for mapping in mappings {
            if mapping.trigger.button?.isProtected == true {
                throw .protectedTrigger(mapping.trigger)
            }
            if case .click(let clicked) = mapping.action, mapping.trigger == .press(clicked.button) {
                throw .selfReferential(mapping.trigger)
            }
            guard byTrigger.updateValue(mapping, forKey: mapping.trigger) == nil else {
                throw .duplicateTrigger(mapping.trigger)
            }
        }
        if let cycle = Self.clickCycle(in: byTrigger) {
            throw .clickCycle(cycle)
        }
        self.init(validated: byTrigger)
    }

    private init(validated mappings: [InputTrigger: ButtonMapping]) {
        self.mappings = mappings
    }

    /// The action for `trigger`; ``Action/passThrough`` when unmapped or disabled.
    public func action(for trigger: InputTrigger) -> Action {
        mappings[trigger]?.effectiveAction ?? .passThrough
    }

    /// Buttons that have at least one swipe mapping, so their press is treated as a tap.
    public var swipeButtons: Set<MouseButton> {
        Set(
            mappings.keys.compactMap { trigger in
                if case .swipe(let button, _) = trigger { button } else { nil }
            }
        )
    }

    /// Finds a cycle in the "pressing A clicks B" graph of enabled mappings.
    private static func clickCycle(in mappings: [InputTrigger: ButtonMapping]) -> [MouseButton]? {
        var clicks: [MouseButton: MouseButton] = [:]
        for (trigger, mapping) in mappings where mapping.isEnabled {
            if case .press(let source) = trigger, case .click(let target) = mapping.action {
                clicks[source] = target.button
            }
        }
        for start in clicks.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            var path = [start]
            var current = start
            while let next = clicks[current] {
                if next == start { return path }
                if path.contains(next) { break }
                path.append(next)
                current = next
            }
        }
        return nil
    }
}
