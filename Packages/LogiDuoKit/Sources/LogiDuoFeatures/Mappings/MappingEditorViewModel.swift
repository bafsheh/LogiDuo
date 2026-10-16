public import LogiDuoDomain
public import Observation

/// Where a trigger's action comes from in the profile being edited.
public enum MappingSource: Hashable, Sendable {
    /// Set in this profile.
    case profile
    /// Inherited from the default profile (application profiles only).
    case inherited
    /// Not mapped anywhere: the button behaves natively.
    case native
}

/// One editable trigger and its current action.
public struct MappingRow: Hashable, Sendable, Identifiable {
    /// The trigger.
    public let trigger: InputTrigger
    /// The action in effect for the profile being edited.
    public let action: Action
    /// Where that action comes from.
    public let source: MappingSource
    /// Whether the trigger needs device button access, which this version does not enable.
    public let needsDeviceAccess: Bool

    public var id: InputTrigger { trigger }
}

/// The groups of triggers shown in the editor.
public enum MappingSection: String, CaseIterable, Hashable, Sendable {
    case buttons
    case gestures
    case scrolling
}

/// Presentation state and intents for editing button mappings.
///
/// Every change is validated with the domain's ``MappingSet`` rules (protected
/// buttons, duplicates, click loops) and, for application profiles, against the
/// default profile, before it is saved; a rejected change is reported and not saved.
@MainActor
@Observable
public final class MappingEditorViewModel {
    /// The configuration being edited.
    public private(set) var configuration = LogiDuoConfiguration.standard
    /// The profile being edited.
    public var profile = ProfileSelection.defaultProfile
    /// The button whose swipe gestures are edited.
    public var gestureButton = MouseButton.middle
    /// Why the last change was refused, if it was.
    public private(set) var lastRejection: MappingRejection?
    /// Why changes are not being saved, if they are not.
    public private(set) var saveProblem: ConfigurationSaveProblem?

    private let repository: any ConfigurationRepositing

    /// Buttons that can carry gestures.
    public static let gestureButtons: [MouseButton] = [.middle, .back, .forward, .gesture]

    /// Creates a view model.
    public init(repository: any ConfigurationRepositing) {
        self.repository = repository
    }

    /// Application profiles, in priority order.
    public var profiles: [StoredProfile] { configuration.profiles }

    /// The rows of `section` for the profile being edited.
    public func rows(in section: MappingSection) -> [MappingRow] {
        triggers(in: section).map(row)
    }

    /// Maps `trigger` to `action` in the profile being edited.
    ///
    /// In the default profile, ``Action/passThrough`` removes the mapping; in an
    /// application profile it is kept as an explicit "native here" override.
    public func setAction(_ action: Action, for trigger: InputTrigger) async {
        await change(trigger) { mappings in
            if case .defaultProfile = self.profile, action == .passThrough { return }
            mappings.append(ButtonMapping(trigger: trigger, action: action))
        }
    }

    /// Removes the profile's own mapping, so the default profile's applies again.
    public func resetToInherited(_ trigger: InputTrigger) async {
        await change(trigger) { _ in }
    }

    /// Follows configuration changes until the calling task is cancelled.
    public func observe() async {
        for await configuration in await repository.updates() {
            self.configuration = configuration
            saveProblem = await repository.saveProblem()
            if case .application(let id) = profile, !configuration.profiles.contains(where: { $0.id == id }) {
                profile = .defaultProfile
            }
        }
    }

    // MARK: - Rows

    private func triggers(in section: MappingSection) -> [InputTrigger] {
        switch section {
        case .buttons: [MouseButton.middle, .back, .forward, .gesture, .modeShift].map(InputTrigger.press)
        case .gestures: SwipeDirection.allCases.map { .swipe(gestureButton, $0) }
        case .scrolling: HorizontalScrollDirection.allCases.map(InputTrigger.horizontalScroll)
        }
    }

    private func row(_ trigger: InputTrigger) -> MappingRow {
        let own = mappings(of: profile).first { $0.trigger == trigger }
        let inherited = configuration.defaultMappings.first { $0.trigger == trigger }
        let (action, source): (Action, MappingSource) =
            if let own {
                (own.action, .profile)
            } else if case .application = profile, let inherited {
                (inherited.action, .inherited)
            } else {
                (.passThrough, .native)
            }
        let needsDevice = trigger.button.map { !$0.isSystemReported } ?? false
        return MappingRow(trigger: trigger, action: action, source: source, needsDeviceAccess: needsDevice)
    }

    private func mappings(of selection: ProfileSelection) -> [ButtonMapping] {
        switch selection {
        case .defaultProfile: configuration.defaultMappings
        case .application(let id): configuration.profiles.first { $0.id == id }?.mappings ?? []
        }
    }

    // MARK: - Changes

    private func change(_ trigger: InputTrigger, _ add: (inout [ButtonMapping]) -> Void) async {
        var mappings = mappings(of: profile).filter { $0.trigger != trigger }
        add(&mappings)
        var candidate = configuration
        switch profile {
        case .defaultProfile:
            candidate.defaultMappings = mappings
        case .application(let id):
            guard let index = candidate.profiles.firstIndex(where: { $0.id == id }) else { return }
            candidate.profiles[index].mappings = mappings
        }
        if let rejection = rejection(in: candidate, for: profile) {
            lastRejection = rejection
            return
        }
        lastRejection = nil
        configuration = candidate
        // Only the edited profile's mappings are written, so concurrent changes elsewhere are kept.
        let profile = profile
        let edited = mappings
        await repository.update { configuration in
            switch profile {
            case .defaultProfile:
                configuration.defaultMappings = edited
            case .application(let id):
                if let index = configuration.profiles.firstIndex(where: { $0.id == id }) {
                    configuration.profiles[index].mappings = edited
                }
            }
        }
    }

    /// Why `candidate` must not be saved: an invalid edited mapping set, or — for an edit to
    /// the default profile — any application profile that was valid and would become invalid
    /// on top of the new defaults (it would otherwise be dropped silently).
    private func rejection(in candidate: LogiDuoConfiguration, for profile: ProfileSelection) -> MappingRejection? {
        let defaults: MappingSet
        do {
            defaults = try MappingSet(candidate.defaultMappings)
        } catch {
            return error
        }
        let checked: [StoredProfile] =
            switch profile {
            case .application(let id): candidate.profiles.filter { $0.id == id }
            case .defaultProfile:
                candidate.profiles.filter(wasValid)
            }
        return checked.lazy.compactMap { Self.overlayRejection($0, on: defaults) }.first
    }

    /// Whether `stored` is valid in the configuration as it is before the change.
    private func wasValid(_ stored: StoredProfile) -> Bool {
        guard let before = configuration.profiles.first(where: { $0.id == stored.id }) else { return false }
        return Self.overlayRejection(before, on: currentDefaults) == nil
    }

    private var currentDefaults: MappingSet { (try? MappingSet(configuration.defaultMappings)) ?? .empty }

    private static func overlayRejection(_ stored: StoredProfile, on defaults: MappingSet) -> MappingRejection? {
        let overrides: MappingSet
        do {
            overrides = try MappingSet(stored.mappings)
        } catch {
            return error
        }
        guard
            let application = ApplicationProfile(
                id: stored.id,
                name: stored.name,
                matchers: stored.matchers,
                overrides: overrides,
                isEnabled: stored.isEnabled
            )
        else { return nil }
        do {
            _ = try ProfileSet(defaultMappings: defaults, applicationProfiles: [application])
        } catch {
            if case .invalidEffectiveMappings(_, let rejection) = error { return rejection }
        }
        return nil
    }
}
