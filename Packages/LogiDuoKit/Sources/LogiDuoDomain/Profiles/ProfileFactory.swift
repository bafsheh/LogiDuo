/// Creates application profiles with stable, unique identifiers. Pure.
public enum ProfileFactory {
    /// What adding an application produced.
    public enum Outcome: Hashable, Sendable {
        /// A new profile.
        case created(StoredProfile)
        /// A profile already applies to this application.
        case existing(ProfileID)
    }

    /// A profile for `application` named `name`, unless one already covers it.
    ///
    /// The identifier is derived from the bundle identifier (`app.com.apple.Safari`)
    /// and suffixed (`~2`, `~3`, …) if a different profile already uses it, so
    /// identifiers never change after creation and never collide.
    public static func profile(
        for application: BundleIdentifier,
        name: String,
        existing: [StoredProfile]
    ) -> Outcome {
        let matcher = ApplicationMatcher.bundleIdentifier(application)
        if let covering = existing.first(where: { $0.matchers.contains(matcher) }) {
            return .existing(covering.id)
        }
        let taken = Set(existing.map(\.id.rawValue))
        let base = "app." + application.description
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)~\(suffix)"
            suffix += 1
        }
        guard
            let id = ProfileID(rawValue: candidate),
            let profileName = ProfileName(name) ?? ProfileName(application.description)
        else { preconditionFailure("derived identifiers and names are never empty") }
        return .created(StoredProfile(id: id, name: profileName, matchers: [matcher]))
    }
}
