/// An absolute path to an executable, compared case-insensitively like the
/// default macOS file system.
public struct ExecutablePath: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The path as written.
    public let value: String
    private let canonical: String

    /// Creates a path, rejecting values that are not absolute.
    public init?(_ value: String) {
        guard value.hasPrefix("/"), value.count > 1 else { return nil }
        self.value = value
        self.canonical = value.lowercased()
    }

    /// Creates a path from its encoded string, validating it.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let path = ExecutablePath(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Path is not absolute")
            )
        }
        self = path
    }

    /// Encodes the path as written.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// Case-insensitive equality.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.canonical == rhs.canonical }

    /// Hashes the case-folded form.
    public func hash(into hasher: inout Hasher) { hasher.combine(canonical) }

    /// The path as written.
    public var description: String { value }
}

/// Something that identifies an application for profile matching.
public enum ApplicationMatcher: Hashable, Sendable, Codable {
    /// Matches an application bundle.
    case bundleIdentifier(BundleIdentifier)
    /// Matches an executable without a usable bundle identifier.
    case executablePath(ExecutablePath)
}

/// The identity of the frontmost application as observed by the system layer.
///
/// References are ordered from most to least specific: for example a helper
/// bundle nested inside an app comes before the enclosing app, and the
/// executable path comes last.
public struct ApplicationIdentity: Hashable, Sendable {
    /// Every reference to the application, most specific first, without duplicates.
    public let references: [ApplicationMatcher]

    /// Creates an identity, removing duplicate references while keeping the first occurrence.
    public init(references: [ApplicationMatcher]) {
        var seen: Set<ApplicationMatcher> = []
        self.references = references.filter { seen.insert($0).inserted }
    }

    /// Creates an identity from bundle identifiers (most specific first) and an optional executable path.
    public init(bundleIdentifiers: [BundleIdentifier], executablePath: ExecutablePath? = nil) {
        self.init(
            references: bundleIdentifiers.map(ApplicationMatcher.bundleIdentifier)
                + (executablePath.map { [.executablePath($0)] } ?? [])
        )
    }
}
