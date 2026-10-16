import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("ProfileFactory")
struct ProfileFactoryTests {
    private static let safari = ProfileFixtures.bundle("com.apple.Safari")

    @Test("a new application gets a profile derived from its bundle identifier")
    func creates() {
        guard case .created(let profile) = ProfileFactory.profile(for: Self.safari, name: "Safari", existing: []) else {
            Issue.record("expected a new profile")
            return
        }
        #expect(profile.id.rawValue == "app.com.apple.Safari")
        #expect(profile.name.value == "Safari")
        #expect(profile.matchers == [.bundleIdentifier(Self.safari)])
    }

    @Test("an application that already has a profile is not added twice")
    func duplicate() {
        let existing = StoredProfile(
            id: ProfileFixtures.id("work"),
            name: ProfileFixtures.name("Work"),
            matchers: [.bundleIdentifier(Self.safari)]
        )
        #expect(
            ProfileFactory.profile(for: Self.safari, name: "Safari", existing: [existing]) == .existing(existing.id)
        )
    }

    @Test("identifiers never collide with an unrelated profile that took the derived identifier")
    func collision() {
        let squatter = StoredProfile(
            id: ProfileFixtures.id("app.com.apple.Safari"),
            name: ProfileFixtures.name("Old"),
            matchers: [ProfileFixtures.app("com.other")]
        )
        guard
            case .created(let profile) = ProfileFactory.profile(for: Self.safari, name: "Safari", existing: [squatter])
        else {
            Issue.record("expected a new profile")
            return
        }
        #expect(profile.id.rawValue == "app.com.apple.Safari~2")
    }

    @Test("a blank name falls back to the bundle identifier")
    func blankName() {
        guard case .created(let profile) = ProfileFactory.profile(for: Self.safari, name: "  ", existing: []) else {
            return
        }
        #expect(profile.name.value == "com.apple.Safari")
    }
}
