public import LogiDuoDomain

/// Builders for profile values in tests.
public enum ProfileFixtures {
    /// A bundle identifier.
    public static func bundle(_ value: String) -> BundleIdentifier {
        unwrap(BundleIdentifier(value))
    }

    /// A bundle-identifier matcher.
    public static func app(_ value: String) -> ApplicationMatcher {
        .bundleIdentifier(bundle(value))
    }

    /// An application profile.
    public static func profile(
        _ id: String,
        name: String? = nil,
        apps: [ApplicationMatcher],
        overrides: [ButtonMapping] = [],
        isEnabled: Bool = true
    ) -> ApplicationProfile {
        let mappings: MappingSet
        do {
            mappings = try MappingSet(overrides)
        } catch {
            preconditionFailure("invalid fixture mappings: \(error)")
        }
        return unwrap(
            ApplicationProfile(
                id: unwrap(ProfileID(rawValue: id)),
                name: unwrap(ProfileName(name ?? id)),
                matchers: apps,
                overrides: mappings,
                isEnabled: isEnabled
            )
        )
    }

    /// A profile identifier.
    public static func id(_ value: String) -> ProfileID {
        unwrap(ProfileID(rawValue: value))
    }

    private static func unwrap<T>(_ value: T?) -> T {
        guard let value else { preconditionFailure("invalid fixture value") }
        return value
    }
}
