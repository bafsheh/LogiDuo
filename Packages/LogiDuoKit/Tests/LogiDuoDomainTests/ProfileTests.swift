import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("Profile values")
struct ProfileValueTests {
    private typealias Fixture = ProfileFixtures

    @Test("profile names are trimmed and must not be blank")
    func names() {
        #expect(ProfileName("  Safari \n")?.value == "Safari")
        #expect(ProfileName("   ") == nil)
        #expect(ProfileID(rawValue: "") == nil)
    }

    @Test("an application profile needs at least one application")
    func requiresMatcher() throws {
        let id = try #require(ProfileID(rawValue: "p"))
        let name = try #require(ProfileName("P"))
        #expect(ApplicationProfile(id: id, name: name, matchers: []) == nil)
    }

    @Test("duplicate matchers are removed in order")
    func deduplicatesMatchers() {
        let profile = Fixture.profile("p", apps: [Fixture.app("a.b"), Fixture.app("A.B"), Fixture.app("c.d")])
        #expect(profile.matchers == [Fixture.app("a.b"), Fixture.app("c.d")])
    }

    @Test("executable paths must be absolute and compare case-insensitively")
    func executablePaths() {
        #expect(ExecutablePath("relative/tool") == nil)
        #expect(ExecutablePath("/") == nil)
        #expect(ExecutablePath("/usr/local/bin/Tool") == ExecutablePath("/usr/local/bin/tool"))
    }

    @Test("application identities drop duplicate references")
    func identityDeduplication() {
        let identity = ApplicationIdentity(bundleIdentifiers: [Fixture.bundle("a.b"), Fixture.bundle("A.b")])
        #expect(identity.references == [Fixture.app("a.b")])
    }
}

@Suite("ProfileSet")
struct ProfileSetTests {
    private typealias Fixture = ProfileFixtures

    private static func defaults() throws -> MappingSet {
        try MappingSet([
            ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)),
            ButtonMapping(trigger: .press(.middle), action: .media(.playPause)),
        ])
    }

    @Test("application overrides inherit unmentioned default mappings")
    func overridesInherit() throws {
        let profile = Fixture.profile(
            "music",
            apps: [Fixture.app("com.apple.Music")],
            overrides: [ButtonMapping(trigger: .press(.back), action: .media(.previousTrack))]
        )
        let set = try ProfileSet(defaultMappings: try Self.defaults(), applicationProfiles: [profile])

        let effective = set.effectiveMappings(for: .application(profile.id))

        #expect(effective.action(for: .press(.back)) == .media(.previousTrack))
        #expect(effective.action(for: .press(.middle)) == .media(.playPause))
        #expect(set.effectiveMappings(for: .defaultProfile).action(for: .press(.back)) == .shortcut(.browserBack))
    }

    @Test("a pass-through override restores native behavior in that application")
    func passThroughOverride() throws {
        let profile = Fixture.profile(
            "games",
            apps: [Fixture.app("com.example.game")],
            overrides: [ButtonMapping(trigger: .press(.middle), action: .passThrough)]
        )
        let set = try ProfileSet(defaultMappings: try Self.defaults(), applicationProfiles: [profile])

        #expect(set.effectiveMappings(for: .application(profile.id)).action(for: .press(.middle)) == .passThrough)
    }

    @Test("rejects duplicate profile identifiers")
    func duplicateIDs() {
        let first = Fixture.profile("x", apps: [Fixture.app("a.a")])
        let second = Fixture.profile("x", apps: [Fixture.app("b.b")])
        #expect(throws: ProfileSetRejection.duplicateProfileID(first.id)) {
            try ProfileSet(defaultMappings: .empty, applicationProfiles: [first, second])
        }
    }

    @Test("rejects an override that completes a click cycle with the defaults")
    func overlayCycle() throws {
        let defaults = try MappingSet([ButtonMapping(trigger: .press(.back), action: .click(.forward))])
        let profile = Fixture.profile(
            "loop",
            apps: [Fixture.app("a.a")],
            overrides: [ButtonMapping(trigger: .press(.forward), action: .click(.back))]
        )
        #expect(throws: ProfileSetRejection.invalidEffectiveMappings(profile.id, .clickCycle([.back, .forward]))) {
            try ProfileSet(defaultMappings: defaults, applicationProfiles: [profile])
        }
    }

    @Test("an unknown selection uses the default mappings")
    func unknownSelection() throws {
        let set = try ProfileSet(defaultMappings: try Self.defaults(), applicationProfiles: [])
        let missing = ProfileSelection.application(Fixture.id("deleted"))

        #expect(!set.contains(missing))
        #expect(set.effectiveMappings(for: missing) == set.defaultMappings)
    }

    @Test("reports applications claimed by several enabled profiles and duplicate names")
    func issues() throws {
        let safari = Fixture.app("com.apple.Safari")
        let set = try ProfileSet(
            defaultMappings: .empty,
            applicationProfiles: [
                Fixture.profile("one", name: "Browser", apps: [safari]),
                Fixture.profile("two", name: "browser", apps: [safari]),
                Fixture.profile("off", apps: [safari], isEnabled: false),
            ]
        )

        #expect(
            set.issues == [
                .sharedMatcher(safari, profiles: [Fixture.id("one"), Fixture.id("two")]),
                .duplicateName("browser", profiles: [Fixture.id("one"), Fixture.id("two")]),
            ]
        )
    }
}

@Suite("ProfileSelector")
struct ProfileSelectorTests {
    private typealias Fixture = ProfileFixtures

    private let selector = ProfileSelector(ignoredApplications: [Fixture.app("io.github.bafsheh.LogiDuo")])

    private func set(_ profiles: ApplicationProfile...) throws -> ProfileSet {
        try ProfileSet(defaultMappings: .empty, applicationProfiles: profiles)
    }

    @Test("selects the profile matching the frontmost application")
    func matchesBundle() throws {
        let profiles = try set(Fixture.profile("safari", apps: [Fixture.app("com.apple.Safari")]))
        let identity = ApplicationIdentity(bundleIdentifiers: [Fixture.bundle("COM.APPLE.SAFARI")])

        #expect(
            selector.selection(for: identity, in: profiles, current: .defaultProfile)
                == .application(Fixture.id("safari"))
        )
    }

    @Test("falls back to the default profile for unmatched or unknown applications")
    func fallback() throws {
        let profiles = try set(Fixture.profile("safari", apps: [Fixture.app("com.apple.Safari")]))
        let other = ApplicationIdentity(bundleIdentifiers: [Fixture.bundle("com.example.Missing")])

        #expect(
            selector.selection(for: other, in: profiles, current: .application(Fixture.id("safari"))) == .defaultProfile
        )
        #expect(
            selector.selection(for: nil, in: profiles, current: .application(Fixture.id("safari"))) == .defaultProfile
        )
    }

    @Test("a more specific reference wins over profile order")
    func specificityBeatsOrder() throws {
        let profiles = try set(
            Fixture.profile("outer", apps: [Fixture.app("com.example.App")]),
            Fixture.profile("inner", apps: [Fixture.app("com.example.App.Helper")])
        )
        let identity = ApplicationIdentity(bundleIdentifiers: [
            Fixture.bundle("com.example.App.Helper"), Fixture.bundle("com.example.App"),
        ])

        #expect(
            selector.selection(for: identity, in: profiles, current: .defaultProfile)
                == .application(Fixture.id("inner"))
        )
    }

    @Test("the outer application matches when the inner one has no profile")
    func outerFallback() throws {
        let profiles = try set(Fixture.profile("outer", apps: [Fixture.app("com.example.App")]))
        let identity = ApplicationIdentity(bundleIdentifiers: [
            Fixture.bundle("com.example.App.Helper"), Fixture.bundle("com.example.App"),
        ])

        #expect(
            selector.selection(for: identity, in: profiles, current: .defaultProfile)
                == .application(Fixture.id("outer"))
        )
    }

    @Test("among equally specific matches the earlier profile wins")
    func orderBreaksTies() throws {
        let safari = Fixture.app("com.apple.Safari")
        let profiles = try set(Fixture.profile("first", apps: [safari]), Fixture.profile("second", apps: [safari]))
        let identity = ApplicationIdentity(references: [safari])

        #expect(
            selector.selection(for: identity, in: profiles, current: .defaultProfile)
                == .application(Fixture.id("first"))
        )
    }

    @Test("disabled profiles never become active")
    func disabledSkipped() throws {
        let safari = Fixture.app("com.apple.Safari")
        let profiles = try set(
            Fixture.profile("off", apps: [safari], isEnabled: false),
            Fixture.profile("on", apps: [safari])
        )

        #expect(
            selector.selection(for: ApplicationIdentity(references: [safari]), in: profiles, current: .defaultProfile)
                == .application(Fixture.id("on"))
        )
    }

    @Test("one profile can cover several related applications")
    func multipleMatchers() throws {
        let profiles = try set(
            Fixture.profile(
                "code",
                apps: [Fixture.app("com.microsoft.VSCode"), Fixture.app("com.microsoft.VSCodeInsiders")]
            )
        )
        let insiders = ApplicationIdentity(bundleIdentifiers: [Fixture.bundle("com.microsoft.VSCodeInsiders")])
        let electron = ApplicationIdentity(bundleIdentifiers: [Fixture.bundle("com.github.Electron")])

        #expect(
            selector.selection(for: insiders, in: profiles, current: .defaultProfile)
                == .application(Fixture.id("code"))
        )
        #expect(selector.selection(for: electron, in: profiles, current: .defaultProfile) == .defaultProfile)
    }

    @Test("matches executables without bundle identifiers")
    func executableMatch() throws {
        let path = try #require(ExecutablePath("/opt/tools/editor"))
        let profiles = try set(Fixture.profile("tool", apps: [.executablePath(path)]))
        let identity = ApplicationIdentity(bundleIdentifiers: [], executablePath: ExecutablePath("/OPT/tools/editor"))

        #expect(
            selector.selection(for: identity, in: profiles, current: .defaultProfile)
                == .application(Fixture.id("tool"))
        )
    }

    @Test("bringing LogiDuo forward keeps the current profile")
    func ignoredApplicationKeepsSelection() throws {
        let profiles = try set(Fixture.profile("safari", apps: [Fixture.app("com.apple.Safari")]))
        let logiDuo = ApplicationIdentity(bundleIdentifiers: [Fixture.bundle("io.github.bafsheh.LogiDuo")])

        #expect(
            selector.selection(for: logiDuo, in: profiles, current: .application(Fixture.id("safari")))
                == .application(Fixture.id("safari"))
        )
    }

    @Test("an ignored application falls back to default if the current profile was deleted")
    func ignoredApplicationWithDeletedProfile() throws {
        let profiles = try set()
        let logiDuo = ApplicationIdentity(bundleIdentifiers: [Fixture.bundle("io.github.bafsheh.LogiDuo")])

        #expect(
            selector.selection(for: logiDuo, in: profiles, current: .application(Fixture.id("gone"))) == .defaultProfile
        )
    }
}
