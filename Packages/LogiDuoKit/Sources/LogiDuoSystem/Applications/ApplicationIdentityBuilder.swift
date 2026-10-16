public import LogiDuoDomain

/// Builds the profile-matching identity of a running application. Pure.
///
/// References, most specific first: the app's own bundle identifier, then the
/// bundle identifier of every enclosing `.app` bundle from the innermost outwards
/// (so a helper inside an app also matches the app), then the executable path.
public enum ApplicationIdentityBuilder {
    /// Reads the bundle identifier of the `.app` bundle at a path.
    public typealias BundleIdentifierLookup = @Sendable (String) -> String?

    /// The identity of an application.
    public static func identity(
        bundleIdentifier: String?,
        bundlePath: String?,
        executablePath: String?,
        lookup: BundleIdentifierLookup
    ) -> ApplicationIdentity {
        var references: [ApplicationMatcher] = []
        if let own = bundleIdentifier.flatMap(BundleIdentifier.init) {
            references.append(.bundleIdentifier(own))
        }
        for path in enclosingBundles(bundlePath) + enclosingBundles(executablePath) {
            if let identifier = lookup(path).flatMap(BundleIdentifier.init) {
                references.append(.bundleIdentifier(identifier))
            }
        }
        if let executable = executablePath.flatMap(ExecutablePath.init) {
            references.append(.executablePath(executable))
        }
        return ApplicationIdentity(references: references)
    }

    /// The `.app` bundles containing `path`, innermost first (including `path` itself).
    static func enclosingBundles(_ path: String?) -> [String] {
        guard let path, path.hasPrefix("/") else { return [] }
        var bundles: [String] = []
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if component.hasSuffix(".app") { bundles.append(current) }
        }
        return bundles.reversed()
    }
}
