/// The profile in effect and the mappings it produces.
public struct ActiveProfile: Hashable, Sendable {
    /// Which profile is selected.
    public let selection: ProfileSelection
    /// Its display name; `nil` for the default profile.
    public let name: String?
    /// The effective mappings (profile overrides on top of the defaults).
    public let mappings: MappingSet

    /// The default profile with no mappings.
    public static let none = ActiveProfile(selection: .defaultProfile, name: nil, mappings: .empty)

    /// Creates a value.
    public init(selection: ProfileSelection, name: String?, mappings: MappingSet) {
        self.selection = selection
        self.name = name
        self.mappings = mappings
    }

    /// Chooses the profile for `application` and computes its mappings. Pure.
    ///
    /// - Parameters:
    ///   - current: The profile in effect so far (kept for ignored applications such as LogiDuo itself).
    ///   - selector: Which applications never switch profiles.
    public static func resolve(
        _ configuration: LogiDuoConfiguration,
        application: ApplicationIdentity?,
        current: ProfileSelection,
        selector: ProfileSelector
    ) -> ActiveProfile {
        let profiles = configuration.profileSet().profiles
        let selection = selector.selection(for: application, in: profiles, current: current)
        let name: String? =
            switch selection {
            case .defaultProfile: nil
            case .application(let id): profiles.applicationProfiles.first { $0.id == id }?.name.value
            }
        return ActiveProfile(selection: selection, name: name, mappings: profiles.effectiveMappings(for: selection))
    }
}
