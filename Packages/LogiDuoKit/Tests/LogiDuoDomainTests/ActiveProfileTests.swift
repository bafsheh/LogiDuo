import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("ActiveProfile")
struct ActiveProfileTests {
    private static let safari = ProfileFixtures.app("com.apple.Safari")
    private static let logiDuo = ProfileFixtures.app("io.github.bafsheh.LogiDuo")

    private static var configuration: LogiDuoConfiguration {
        var configuration = LogiDuoConfiguration.standard
        configuration.defaultMappings = [
            ButtonMapping(trigger: .press(.back), action: .system(.missionControl)),
            ButtonMapping(trigger: .press(.forward), action: .click(.middle)),
        ]
        configuration.profiles = [
            StoredProfile(
                id: ProfileFixtures.id("safari"),
                name: ProfileFixtures.name("Safari"),
                matchers: [safari],
                mappings: [ButtonMapping(trigger: .press(.back), action: .shortcut(.previousTab))]
            )
        ]
        return configuration
    }

    private static let selector = ProfileSelector(ignoredApplications: [logiDuo])

    @Test("an application with a profile gets its overrides on top of the defaults")
    func applicationProfile() {
        let active = ActiveProfile.resolve(
            Self.configuration,
            application: ApplicationIdentity(references: [Self.safari]),
            current: .defaultProfile,
            selector: Self.selector
        )
        #expect(active.name == "Safari")
        #expect(active.mappings.action(for: .press(.back)) == .shortcut(.previousTab))
        #expect(active.mappings.action(for: .press(.forward)) == .click(.middle))
    }

    @Test("other applications use the default profile")
    func defaultProfile() {
        let active = ActiveProfile.resolve(
            Self.configuration,
            application: ApplicationIdentity(references: [ProfileFixtures.app("com.apple.finder")]),
            current: .application(ProfileFixtures.id("safari")),
            selector: Self.selector
        )
        #expect(active.selection == .defaultProfile)
        #expect(active.name == nil)
        #expect(active.mappings.action(for: .press(.back)) == .system(.missionControl))
    }

    @Test("switching to LogiDuo itself keeps the current profile")
    func ignoresOwnApp() {
        let active = ActiveProfile.resolve(
            Self.configuration,
            application: ApplicationIdentity(references: [Self.logiDuo]),
            current: .application(ProfileFixtures.id("safari")),
            selector: Self.selector
        )
        #expect(active.name == "Safari")
    }

    @Test("a nested helper app matches its enclosing application's profile")
    func nestedHelper() {
        let active = ActiveProfile.resolve(
            Self.configuration,
            application: ApplicationIdentity(references: [ProfileFixtures.app("com.apple.Safari.helper"), Self.safari]),
            current: .defaultProfile,
            selector: Self.selector
        )
        #expect(active.name == "Safari")
    }
}
