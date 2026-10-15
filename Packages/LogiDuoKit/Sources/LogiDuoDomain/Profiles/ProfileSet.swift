/// Why a set of profiles was rejected.
public enum ProfileSetRejection: Error, Hashable, Sendable {
    /// Two application profiles share an identifier.
    case duplicateProfileID(ProfileID)
    /// Overlaying a profile on the default mappings breaks a mapping invariant
    /// (for example it completes a click cycle).
    case invalidEffectiveMappings(ProfileID, MappingRejection)
}

/// A non-fatal problem in a set of profiles.
public enum ProfileIssue: Hashable, Sendable {
    /// Several enabled profiles claim the same application; the first listed wins.
    case sharedMatcher(ApplicationMatcher, profiles: [ProfileID])
    /// Several profiles have the same name (case-insensitive).
    case duplicateName(String, profiles: [ProfileID])
}

/// The default profile together with the ordered application profiles.
///
/// Invariants established at construction: there is exactly one default
/// profile, application profile identifiers are unique, and every
/// application profile overlaid on the default mappings forms a valid
/// ``MappingSet``. Order matters: it breaks ties between profiles that match
/// the same application equally specifically.
public struct ProfileSet: Hashable, Sendable {
    /// Mappings used when no application profile applies.
    public let defaultMappings: MappingSet
    /// Application profiles, in precedence order.
    public let applicationProfiles: [ApplicationProfile]
    private let effective: [ProfileID: MappingSet]

    /// A profile set with no mappings and no application profiles.
    public static let empty = ProfileSet(validatedDefault: .empty, profiles: [], effective: [:])

    /// Creates a profile set.
    /// - Throws: ``ProfileSetRejection`` for duplicate identifiers or invalid overlays.
    public init(defaultMappings: MappingSet, applicationProfiles: [ApplicationProfile]) throws(ProfileSetRejection) {
        var effective: [ProfileID: MappingSet] = [:]
        for profile in applicationProfiles {
            guard effective[profile.id] == nil else { throw .duplicateProfileID(profile.id) }
            effective[profile.id] = try Self.overlay(profile, on: defaultMappings)
        }
        self.init(validatedDefault: defaultMappings, profiles: applicationProfiles, effective: effective)
    }

    private init(validatedDefault: MappingSet, profiles: [ApplicationProfile], effective: [ProfileID: MappingSet]) {
        self.defaultMappings = validatedDefault
        self.applicationProfiles = profiles
        self.effective = effective
    }

    /// The mappings in effect for `selection`; the default mappings if the
    /// selected profile no longer exists.
    public func effectiveMappings(for selection: ProfileSelection) -> MappingSet {
        switch selection {
        case .defaultProfile: defaultMappings
        case .application(let id): effective[id] ?? defaultMappings
        }
    }

    /// Whether `selection` refers to a profile in this set.
    public func contains(_ selection: ProfileSelection) -> Bool {
        switch selection {
        case .defaultProfile: true
        case .application(let id): effective[id] != nil
        }
    }

    /// Non-fatal problems, in a stable order.
    public var issues: [ProfileIssue] {
        var claims: [ApplicationMatcher: [ProfileID]] = [:]
        var order: [ApplicationMatcher] = []
        var names: [String: [ProfileID]] = [:]
        var nameOrder: [String] = []
        for profile in applicationProfiles {
            let key = profile.name.value.lowercased()
            if names[key] == nil { nameOrder.append(key) }
            names[key, default: []].append(profile.id)
            guard profile.isEnabled else { continue }
            for matcher in profile.matchers {
                if claims[matcher] == nil { order.append(matcher) }
                claims[matcher, default: []].append(profile.id)
            }
        }
        let shared = order.compactMap { matcher in
            claims[matcher].flatMap { $0.count > 1 ? ProfileIssue.sharedMatcher(matcher, profiles: $0) : nil }
        }
        let duplicateNames = nameOrder.compactMap { key in
            names[key].flatMap { $0.count > 1 ? ProfileIssue.duplicateName(key, profiles: $0) : nil }
        }
        return shared + duplicateNames
    }

    private static func overlay(
        _ profile: ApplicationProfile,
        on defaults: MappingSet
    ) throws(ProfileSetRejection) -> MappingSet {
        let merged = defaults.mappings.merging(profile.overrides.mappings) { _, override in override }
        do {
            return try MappingSet(Array(merged.values))
        } catch {
            throw .invalidEffectiveMappings(profile.id, error)
        }
    }
}
