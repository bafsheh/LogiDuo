import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("MouserImporter")
struct MouserImportTests {
    /// A real version 9 configuration (Mouser's last public schema).
    static let version9 = #"""
        {"version": 9, "active_profile": "default",
         "profiles": {"default": {"label": "Default (All Apps)", "apps": [],
           "mappings": {"middle": "none", "gesture": "none", "gesture_left": "none", "gesture_right": "none",
             "gesture_up": "none", "gesture_down": "none", "xbutton1": "alt_tab", "xbutton2": "alt_tab",
             "hscroll_left": "none", "hscroll_right": "none", "mode_shift": "mission_control"}}},
         "settings": {"start_minimized": true, "start_at_login": true, "hscroll_threshold": 1, "invert_hscroll": false,
           "invert_vscroll": false, "dpi": 1000, "smart_shift_mode": "freespin", "smart_shift_enabled": false,
           "smart_shift_threshold": 25, "gesture_threshold": 50, "ignore_trackpad": true}}
        """#

    private static func preview(
        _ json: String,
        resolver: @escaping MouserImporter.ApplicationResolver = MouserImporter.basicResolver
    ) throws -> MouserImportPreview {
        try MouserImporter.preview(Data(json.utf8), resolveApplication: resolver)
    }

    private static func profile(_ mappings: String, version: Int = 11, settings: String = "{}") -> String {
        #"{"version": \#(version), "profiles": {"default": {"mappings": \#(mappings)}}, "settings": \#(settings)}"#
    }

    @Test("the user's version 9 configuration imports its mappings and settings")
    func version9() throws {
        let preview = try Self.preview(Self.version9)

        #expect(preview.sourceVersion == 9)
        #expect(
            Set(preview.defaultMappings) == [
                ButtonMapping(trigger: .press(.back), action: .shortcut(.switchApplications)),
                ButtonMapping(trigger: .press(.forward), action: .shortcut(.switchApplications)),
                ButtonMapping(trigger: .press(.modeShift), action: .system(.missionControl)),
            ]
        )
        #expect(preview.pointer.resolution == 1000)
        #expect(preview.pointer.smartShift == .freeSpin)
        #expect(preview.gestureThreshold == 50)
        #expect(preview.scroll.horizontalActionThreshold == 0.1, "v9→v10 turned the old default 1 into 0.1")
        #expect(preview.scroll.ignoreTrackpad)
        #expect(preview.notes == [.startAtLoginNotImported])
    }

    @Test("old schemas go through Mouser's migrations (v6–v8 mode shift defaults)")
    func migrations() throws {
        let preview = try Self.preview(Self.profile(#"{"middle": "copy"}"#, version: 5))
        #expect(
            preview.defaultMappings.contains(
                ButtonMapping(trigger: .press(.modeShift), action: .device(.toggleScrollMode))
            )
        )
        #expect(preview.defaultMappings.contains(ButtonMapping(trigger: .press(.middle), action: .shortcut(.copy))))
    }

    @Test(
        "unusable files are refused with a reason",
        arguments: [
            ("not json", MouserImportError.notJSON),
            (#"{"version": 12, "profiles": {"default": {}}}"#, .newerVersion(12)),
            (#"{"version": "nine", "profiles": {"default": {}}}"#, .invalidVersion),
            (#"{"version": 9, "profiles": {}}"#, .noProfiles),
            (#"[1, 2]"#, .notJSON),
        ]
    )
    func refused(json: String, error: MouserImportError) {
        #expect(throws: error) { try Self.preview(json) }
    }

    @Test("an incomplete file falls back to defaults")
    func incomplete() throws {
        let preview = try Self.preview(#"{"profiles": {"default": {}}}"#)
        #expect(preview.sourceVersion == 1)
        #expect(preview.pointer.resolution == nil)
        #expect(preview.scroll.ignoreTrackpad)
    }

    @Test("unsupported actions and buttons are reported, the rest imported")
    func unsupported() throws {
        let preview = try Self.preview(
            Self.profile(
                #"""
                {"middle": "task_view", "xbutton1": "play_pause", "actions_ring": "activate_actions_ring",
                 "xbutton2": "cycle_desktops"}
                """#
            )
        )
        #expect(preview.defaultMappings == [ButtonMapping(trigger: .press(.back), action: .media(.playPause))])
        #expect(preview.notes.contains(.unsupportedAction(button: "middle", action: "task_view")))
        #expect(preview.notes.contains(.unsupportedAction(button: "xbutton2", action: "cycle_desktops")))
        #expect(preview.notes.contains(.unsupportedButton("actions_ring")))
    }

    @Test("custom shortcuts are parsed into key combinations")
    func customShortcut() throws {
        let preview = try Self.preview(
            Self.profile(
                #"{"middle": "custom:cmd+shift+4", "xbutton1": "custom:ctrl+alt+f5", "xbutton2": "custom:hyper+q"}"#
            )
        )
        let actions = Dictionary(uniqueKeysWithValues: preview.defaultMappings.map { ($0.trigger, $0.action) })
        guard case .customShortcut(let middle)? = actions[.press(.middle)],
            case .customShortcut(let back)? = actions[.press(.back)]
        else {
            Issue.record("expected custom shortcuts")
            return
        }
        #expect(middle.displayString == "⇧⌘4")
        #expect(back.displayString == "⌃⌥F5")
        #expect(preview.notes.contains(.unsupportedAction(button: "xbutton2", action: "custom:hyper+q")))
    }

    @Test("gesture swipes: the sentinel's tap becomes the click; old configs with only swipes keep them")
    func gestureSwipe() throws {
        let sentinel = try Self.preview(
            Self.profile(
                #"""
                {"gesture": "gesture_swipe", "gesture_tap": "copy", "gesture_left": "next_tab",
                 "middle": "gesture_swipe", "middle_up": "mission_control"}
                """#
            )
        )
        #expect(
            Set(sentinel.defaultMappings) == [
                ButtonMapping(trigger: .press(.gesture), action: .shortcut(.copy)),
                ButtonMapping(trigger: .swipe(.gesture, .left), action: .shortcut(.nextTab)),
                ButtonMapping(trigger: .swipe(.middle, .up), action: .system(.missionControl)),
            ]
        )
        let legacy = try Self.preview(Self.profile(#"{"gesture": "none", "gesture_right": "next_tab"}"#, version: 9))
        #expect(
            legacy.defaultMappings == [ButtonMapping(trigger: .swipe(.gesture, .right), action: .shortcut(.nextTab))]
        )
    }

    @Test("profiles import when their applications are identified; others are reported")
    func profiles() throws {
        let json = #"""
            {"version": 11, "profiles": {
              "default": {"mappings": {}},
              "browser": {"label": "Browser", "apps": ["com.apple.Safari", "Safari"],
                          "mappings": {"xbutton1": "prev_tab"}},
              "unknown": {"label": "Mystery", "apps": ["Mystery App"], "mappings": {"middle": "copy"}}}}
            """#
        let preview = try Self.preview(json)
        #expect(preview.profiles.map(\.name.value) == ["Browser"])
        #expect(preview.profiles.first?.matchers == [ProfileFixtures.app("com.apple.Safari")])
        #expect(preview.notes.contains(.unknownApplication(profile: "Browser", application: "Safari")))
        #expect(preview.notes.contains(.skippedProfile("Mystery")))

        let resolver: MouserImporter.ApplicationResolver = { entry in
            entry == "Mystery App" ? ProfileFixtures.app("com.example.mystery") : MouserImporter.basicResolver(entry)
        }
        let resolved = try Self.preview(json, resolver: resolver)
        #expect(resolved.profiles.count == 2)
    }

    @Test("a click loop is broken by leaving one mapping out; self-clicks are native and skipped")
    func conflicts() throws {
        let preview = try Self.preview(
            Self.profile(
                #"{"xbutton1": "mouse_forward_click", "xbutton2": "mouse_back_click", "middle": "mouse_middle_click"}"#
            )
        )
        #expect(preview.defaultMappings == [ButtonMapping(trigger: .press(.back), action: .click(.forward))])
        #expect(preview.notes.count == 1)
        guard case .conflictingMapping = preview.notes.first else {
            Issue.record("expected a conflict note")
            return
        }
    }

    @Test("applying replaces mappings and scroll settings and keeps everything else")
    func applied() throws {
        var current = LogiDuoConfiguration.standard
        current.general.remappingEnabled = true
        current.general.showsWindowAtLaunch = false
        current.defaultMappings = [ButtonMapping(trigger: .press(.middle), action: .media(.mute))]
        let preview = try Self.preview(Self.version9)

        let result = preview.applied(to: current, mice: [.fixture(1)])

        #expect(result.general.remappingEnabled && !result.general.showsWindowAtLaunch)
        #expect(result.defaultMappings == preview.defaultMappings)
        #expect(result.settings(for: .fixture(1)).resolution == 1000)
        #expect(result.general.gestureThreshold == 50)
    }
}
