import Foundation
import LogiDuoDomain
import Testing

@Suite("Localization coverage")
struct LocalizationCoverageTests {
    /// The keys of the Features string catalog, read from the source file.
    private static func catalogKeys() throws -> Set<String> {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LogiDuoFeatures/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        let strings = object?["strings"] as? [String: Any] ?? [:]
        return Set(strings.keys)
    }

    @Test("every action, action category and trigger has a localized title")
    func everyTitle() throws {
        let keys = try Self.catalogKeys()
        let expected =
            ActionCatalog.choices.map { "action." + $0.id }
            + ActionCategory.allCases.map { "action.category." + $0.rawValue }
            + MouseButton.allCases.map { "trigger.press." + $0.rawValue }
            + SwipeDirection.allCases.map { "trigger.swipe." + $0.rawValue }
            + HorizontalScrollDirection.allCases.map { "trigger.hscroll." + $0.rawValue }
        let missing = expected.filter { !keys.contains($0) }
        #expect(missing.isEmpty, "missing: \(missing)")
    }
}
