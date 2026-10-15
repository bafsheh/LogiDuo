/// The global remapping switch.
public enum RemappingMode: Hashable, Sendable {
    /// Mappings are applied.
    case enabled
    /// Every input behaves natively: nothing is intercepted, suppressed or diverted.
    case disabled
}

/// Why a stored mapping is not in effect.
public enum MappingIssue: Hashable, Sendable {
    /// The device cannot report the trigger (for example a button it does not divert).
    case triggerUnavailable(InputTrigger)
    /// The device's capabilities are not discovered yet; the mapping activates once they are.
    case triggerPending(InputTrigger)
    /// The action needs a device capability that is unavailable or not yet discovered.
    case actionRequiresCapability(InputTrigger, DeviceAction, Availability)
    /// The action is not understood by this version of LogiDuo.
    case unsupportedAction(InputTrigger, identifier: String)
}

/// The mappings that are actually in effect for one device, derived from
/// stored mappings, device capabilities and the remapping switch.
///
/// Anything not in effect behaves natively. Stored mappings are never
/// discarded by resolution: when capabilities change, resolving again
/// re-activates mappings that became possible.
public struct ResolvedMappings: Hashable, Sendable {
    /// Nothing intercepted; every input is native.
    public static let passThrough = ResolvedMappings(actions: [:], swipeButtons: [], issues: [])

    /// Effective actions for triggers that LogiDuo handles.
    public let actions: [InputTrigger: Action]
    /// Buttons whose presses must be held back to detect swipes. A release
    /// without a swipe is a tap: it runs the press action, or replays the
    /// native click when the press itself is not mapped.
    public let swipeButtons: Set<MouseButton>
    /// Stored mappings that are not in effect, in a stable order.
    public let issues: [MappingIssue]

    /// The action for `trigger`; ``Action/passThrough`` if LogiDuo does not handle it.
    public func action(for trigger: InputTrigger) -> Action {
        actions[trigger] ?? .passThrough
    }

    /// Buttons whose events LogiDuo must intercept.
    public var interceptedButtons: Set<MouseButton> {
        swipeButtons.union(actions.keys.compactMap(\.button))
    }

    /// Intercepted buttons that the device must divert over HID++ because macOS does not report them.
    public var buttonsRequiringDiversion: Set<MouseButton> {
        interceptedButtons.filter { !$0.isSystemReported }
    }
}

/// Decides which stored mappings take effect on a device.
public enum MappingResolver {
    /// Resolves `mappings` for a device with `capabilities`.
    ///
    /// Rules:
    /// * ``RemappingMode/disabled`` yields ``ResolvedMappings/passThrough``.
    /// * Disabled and pass-through mappings are not intercepted.
    /// * A mapping whose trigger the device cannot report, or whose device
    ///   action needs a capability that is not available, is reported and stays native.
    /// * Unknown actions are reported and stay native.
    public static func resolve(
        _ mappings: MappingSet,
        capabilities: MouseCapabilities,
        mode: RemappingMode
    ) -> ResolvedMappings {
        guard mode == .enabled else { return .passThrough }
        var actions: [InputTrigger: Action] = [:]
        var swipeButtons: Set<MouseButton> = []
        var issues: [MappingIssue] = []
        for mapping in mappings.mappings.values.sorted(by: { $0.trigger.sortKey < $1.trigger.sortKey })
        where mapping.isEnabled {
            if let issue = issue(for: mapping, capabilities: capabilities) {
                issues.append(issue)
                continue
            }
            guard !mapping.action.isPassThrough else { continue }
            actions[mapping.trigger] = mapping.action
            if case .swipe(let button, _) = mapping.trigger {
                swipeButtons.insert(button)
            }
        }
        return ResolvedMappings(actions: actions, swipeButtons: swipeButtons, issues: issues)
    }

    private static func issue(for mapping: ButtonMapping, capabilities: MouseCapabilities) -> MappingIssue? {
        if case .unsupported(let unsupported) = mapping.action {
            return .unsupportedAction(mapping.trigger, identifier: unsupported.identifier)
        }
        switch triggerAvailability(mapping.trigger, capabilities: capabilities) {
        case .unavailable: return .triggerUnavailable(mapping.trigger)
        case .pending: return .triggerPending(mapping.trigger)
        case .available: break
        }
        if case .device(let action) = mapping.action {
            let availability = action.availability(with: capabilities)
            if availability != .available {
                return .actionRequiresCapability(mapping.trigger, action, availability)
            }
        }
        return nil
    }

    private static func triggerAvailability(_ trigger: InputTrigger, capabilities: MouseCapabilities) -> Availability {
        switch trigger {
        case .horizontalScroll:
            return .available
        case .press(let button):
            return capabilities.remapAvailability(for: button)
        case .swipe(let button, _):
            let press = capabilities.remapAvailability(for: button)
            guard press == .available, !button.isSystemReported else { return press }
            switch capabilities.gestures {
            case .undiscovered: return .pending
            case .unsupported: return .unavailable
            case .supported(let gestures):
                return gestures.supportsDirectionalSwipes && gestures.buttons.contains(button)
                    ? .available : .unavailable
            }
        }
    }
}

extension DeviceAction {
    /// Whether the device can perform this action.
    public func availability(with capabilities: MouseCapabilities) -> Availability {
        switch self {
        case .cycleResolutionPresets: capabilities.resolution.availability
        case .toggleSmartShift, .toggleScrollMode: capabilities.smartShift.availability
        }
    }
}

extension InputTrigger {
    /// A total order used to make resolution output deterministic.
    var sortKey: String {
        switch self {
        case .press(let button): "0.\(button.rawValue)"
        case .swipe(let button, let direction): "1.\(button.rawValue).\(direction.rawValue)"
        case .horizontalScroll(let direction): "2.\(direction.rawValue)"
        }
    }
}
