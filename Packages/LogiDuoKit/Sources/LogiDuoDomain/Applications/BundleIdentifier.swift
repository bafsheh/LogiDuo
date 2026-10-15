/// A macOS application bundle identifier, compared case-insensitively.
///
/// Bundle identifiers are case-insensitive on macOS, so `com.Apple.Safari` and
/// `com.apple.safari` are equal; the original spelling is kept for display.
public struct BundleIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The identifier as written.
    public let value: String
    private let canonical: String

    /// Creates a bundle identifier, rejecting values that are empty, contain
    /// characters other than ASCII letters, digits, `.` and `-`, or have empty components.
    public init?(_ value: String) {
        let allowed = value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "." || scalar == "-")
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, allowed, !components.contains(where: \.isEmpty) else { return nil }
        self.value = value
        self.canonical = value.lowercased()
    }

    /// Creates a bundle identifier from its encoded string, validating it.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let identifier = BundleIdentifier(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid bundle identifier")
            )
        }
        self = identifier
    }

    /// Encodes the identifier as written.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// Case-insensitive equality.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.canonical == rhs.canonical }

    /// Hashes the case-folded form.
    public func hash(into hasher: inout Hasher) { hasher.combine(canonical) }

    /// The identifier as written.
    public var description: String { value }
}
