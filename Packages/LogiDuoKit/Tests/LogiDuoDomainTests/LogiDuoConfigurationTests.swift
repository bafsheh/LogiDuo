import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("LogiDuoConfiguration")
struct LogiDuoConfigurationTests {
    private static func decode(_ json: String) throws -> LogiDuoConfiguration {
        try JSONDecoder().decode(LogiDuoConfiguration.self, from: Data(json.utf8))
    }

    private static let safari = ProfileFixtures.app("com.apple.Safari")

    @Test("an empty document yields the first-launch defaults")
    func emptyDocument() throws {
        #expect(try Self.decode("{}") == .standard)
        #expect(!LogiDuoConfiguration.standard.general.remappingEnabled)
    }

    @Test("round-trips every field")
    func roundTrip() throws {
        var configuration = LogiDuoConfiguration.standard
        configuration.defaultMappings = [ButtonMapping(trigger: .press(.back), action: .system(.missionControl))]
        configuration.profiles = [
            StoredProfile(
                id: ProfileFixtures.id("safari"),
                name: ProfileFixtures.name("Safari"),
                matchers: [Self.safari],
                mappings: [ButtonMapping(trigger: .press(.forward), action: .shortcut(.nextTab))]
            )
        ]
        configuration.scroll.invertVertical = true
        configuration.general.remappingEnabled = true
        configuration.devices[.fixture(1)] = DeviceSettings(
            resolution: 1600,
            resolutionPresets: [800, 1600],
            smartShift: .automatic(sensitivity: 12)
        )

        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(LogiDuoConfiguration.self, from: data) == configuration)
    }

    @Test("an unreadable field falls back to its default without losing the others")
    func lenientFields() throws {
        let configuration = try Self.decode(
            #"{"scroll": {"invertVertical": "yes", "invertHorizontal": true}, "general": 42}"#
        )
        #expect(!configuration.scroll.invertVertical)
        #expect(configuration.scroll.invertHorizontal)
        #expect(configuration.general == .standard)
    }

    @Test("an unreadable list element is dropped, the rest kept")
    func lenientElements() throws {
        let configuration = try Self.decode(
            #"""
            {"profiles": [
              {"id": "a", "name": "A", "matchers": [{"bundleIdentifier": {"_0": "com.apple.Safari"}}]},
              {"id": "", "name": "Broken"},
              {"id": "b", "name": "   "}
            ]}
            """#
        )
        #expect(configuration.profiles.map(\.id.rawValue) == ["a"])
    }

    @Test("values are clamped to safe ranges")
    func clamping() {
        #expect(
            GeneralSettings(remappingEnabled: false, showsWindowAtLaunch: true, gestureThreshold: 1).gestureThreshold
                == 8
        )
        #expect(
            DeviceSettings(resolution: -5, resolutionPresets: [800, 800, 0, 1600], smartShift: nil)
                == DeviceSettings(resolution: nil, resolutionPresets: [800, 1600], smartShift: nil)
        )
    }

    @Test("invalid mappings and profiles are left out and reported")
    func profileSetIssues() {
        var configuration = LogiDuoConfiguration.standard
        configuration.defaultMappings = [ButtonMapping(trigger: .press(.middle), action: .click(.middle))]
        configuration.profiles = [
            StoredProfile(id: ProfileFixtures.id("empty"), name: ProfileFixtures.name("Empty"), matchers: []),
            StoredProfile(id: ProfileFixtures.id("ok"), name: ProfileFixtures.name("OK"), matchers: [Self.safari]),
            StoredProfile(id: ProfileFixtures.id("ok"), name: ProfileFixtures.name("Again"), matchers: [Self.safari]),
        ]

        let (profiles, issues) = configuration.profileSet()

        #expect(profiles.defaultMappings == .empty)
        #expect(profiles.applicationProfiles.map(\.id.rawValue) == ["ok"])
        #expect(
            issues == [
                .invalidDefaultMappings(.selfReferential(.press(.middle))),
                .invalidProfile(ProfileFixtures.id("empty")),
                .duplicateProfile(ProfileFixtures.id("ok")),
            ]
        )
    }

    @Test("profile names are validated when decoded")
    func profileNameDecoding() throws {
        #expect(try JSONDecoder().decode(ProfileName.self, from: Data(#""  Work  ""#.utf8)).value == "Work")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProfileName.self, from: Data(#""   ""#.utf8)) }
    }
}
