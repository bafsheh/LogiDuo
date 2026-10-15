/// Chooses the active profile for the frontmost application.
///
/// Rules, in order:
/// 1. An application in ``ignoredApplications`` (typically LogiDuo itself)
///    keeps the current selection, so configuring LogiDuo does not switch profiles.
/// 2. The application's references are tried from most to least specific; for
///    each, the first enabled profile (in set order) with a matching matcher wins.
/// 3. Otherwise — including when no application is known or a profile's
///    application is not installed — the default profile applies.
///
/// A current selection that no longer exists in the set falls back to the default.
public struct ProfileSelector: Hashable, Sendable {
    /// Applications that never cause a profile switch.
    public let ignoredApplications: Set<ApplicationMatcher>

    /// Creates a selector.
    public init(ignoredApplications: Set<ApplicationMatcher> = []) {
        self.ignoredApplications = ignoredApplications
    }

    /// The profile that should be active.
    /// - Parameters:
    ///   - application: The frontmost application, or `nil` if unknown.
    ///   - profiles: The configured profiles.
    ///   - current: The selection currently in effect.
    public func selection(
        for application: ApplicationIdentity?,
        in profiles: ProfileSet,
        current: ProfileSelection
    ) -> ProfileSelection {
        let fallback = profiles.contains(current) ? current : .defaultProfile
        guard let application else { return .defaultProfile }
        if application.references.contains(where: ignoredApplications.contains) {
            return fallback
        }
        for reference in application.references {
            let match = profiles.applicationProfiles.first { $0.isEnabled && $0.matchers.contains(reference) }
            if let match {
                return .application(match.id)
            }
        }
        return .defaultProfile
    }
}
