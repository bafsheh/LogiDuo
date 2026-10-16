import AppKit
public import LogiDuoDomain

/// Identifies applications named in other apps' settings (bundle identifiers, paths or
/// names such as "Safari") using the applications installed on this Mac.
public enum InstalledApplicationResolver {
    /// Resolves `entry` to a matcher, or `nil` if no such application is installed.
    @Sendable
    public static func resolve(_ entry: String) -> ApplicationMatcher? {
        if let basic = MouserImporter.basicResolver(entry) { return basic }
        let name = entry.hasSuffix(".app") ? String(entry.dropLast(4)) : entry
        let candidates =
            (entry.hasPrefix("/") ? [URL(fileURLWithPath: entry)] : [])
            + ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
        for url in candidates {
            if let identifier = Bundle(url: url)?.bundleIdentifier.flatMap(BundleIdentifier.init) {
                return .bundleIdentifier(identifier)
            }
        }
        return nil
    }
}
