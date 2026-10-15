/// A stable identifier for an application profile.
public struct ProfileID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The identifier string; never empty.
    public let rawValue: String

    /// Creates an identifier, rejecting empty or whitespace-only values.
    public init?(rawValue: String) {
        guard rawValue.contains(where: { !$0.isWhitespace }) else { return nil }
        self.rawValue = rawValue
    }

    /// The identifier string.
    public var description: String { rawValue }
}

/// A user-visible profile name: trimmed and never empty.
public struct ProfileName: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The trimmed name.
    public let value: String

    /// Creates a name, trimming whitespace and rejecting empty results.
    public init?(_ value: String) {
        let trimmed = String(value.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    /// The trimmed name.
    public var description: String { value }
}

/// A profile that applies while one of its applications is frontmost.
///
/// Its mappings are *overrides*: triggers it does not mention inherit the
/// default profile's behavior. An override with ``Action/passThrough``
/// restores native behavior for that trigger in this application.
public struct ApplicationProfile: Hashable, Sendable, Identifiable {
    /// The profile's identity.
    public let id: ProfileID
    /// The display name.
    public let name: ProfileName
    /// Applications this profile applies to; never empty, without duplicates.
    public let matchers: [ApplicationMatcher]
    /// Mapping overrides on top of the default profile.
    public let overrides: MappingSet
    /// A disabled profile never becomes active.
    public let isEnabled: Bool

    /// Creates a profile, rejecting an empty matcher list. Duplicate matchers are removed.
    public init?(
        id: ProfileID,
        name: ProfileName,
        matchers: [ApplicationMatcher],
        overrides: MappingSet = .empty,
        isEnabled: Bool = true
    ) {
        var seen: Set<ApplicationMatcher> = []
        let unique = matchers.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        self.id = id
        self.name = name
        self.matchers = unique
        self.overrides = overrides
        self.isEnabled = isEnabled
    }
}

/// Which profile is in effect.
public enum ProfileSelection: Hashable, Sendable {
    /// The default profile.
    case defaultProfile
    /// An application profile.
    case application(ProfileID)
}
