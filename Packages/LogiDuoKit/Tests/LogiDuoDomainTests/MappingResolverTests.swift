import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("MappingResolver")
struct MappingResolverTests {
    private static let gestureMouse: MouseCapabilities = {
        guard
            let gestures = GestureCapability(buttons: [.gesture], supportsDirectionalSwipes: true),
            let range = ResolutionRange(minimum: 200, maximum: 8000, step: 50)
        else { preconditionFailure("valid fixture") }
        return MouseCapabilities(
            divertableButtons: .supported([.gesture, .modeShift]),
            resolution: .supported(range),
            smartShift: .supported(SmartShiftCapability(supportsTunableTorque: true)),
            gestures: .supported(gestures)
        )
    }()

    private static func set(_ mappings: ButtonMapping...) throws -> MappingSet {
        try MappingSet(mappings)
    }

    @Test("applies supported mappings and leaves everything else native")
    func appliesSupportedMappings() throws {
        let mappings = try Self.set(
            ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)),
            ButtonMapping(trigger: .swipe(.gesture, .up), action: .system(.missionControl)),
            ButtonMapping(trigger: .press(.modeShift), action: .device(.toggleScrollMode))
        )

        let resolved = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled)

        #expect(resolved.issues.isEmpty)
        #expect(resolved.action(for: .press(.back)) == .shortcut(.browserBack))
        #expect(resolved.action(for: .press(.forward)) == .passThrough)
        #expect(resolved.interceptedButtons == [.back, .gesture, .modeShift])
        #expect(resolved.buttonsRequiringDiversion == [.gesture, .modeShift])
        #expect(resolved.swipeButtons == [.gesture])
    }

    @Test("disabled remapping restores native behavior for every input")
    func disabledRemappingIsNative() throws {
        let mappings = try Self.set(
            ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)),
            ButtonMapping(trigger: .swipe(.gesture, .up), action: .system(.missionControl))
        )

        let resolved = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .disabled)

        #expect(resolved == .passThrough)
        #expect(resolved.interceptedButtons.isEmpty)
        #expect(resolved.buttonsRequiringDiversion.isEmpty)
        #expect(resolved.action(for: .press(.back)) == .passThrough)
    }

    @Test("a disabled mapping is not intercepted and raises no issue")
    func disabledMapping() throws {
        let mappings = try Self.set(ButtonMapping(trigger: .press(.thumb), action: .media(.mute), isEnabled: false))

        let resolved = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled)

        #expect(resolved == .passThrough)
    }

    @Test("an explicit pass-through mapping is not intercepted")
    func explicitPassThrough() throws {
        let mappings = try Self.set(
            ButtonMapping(trigger: .press(.middle), action: .passThrough),
            ButtonMapping(trigger: .swipe(.gesture, .left), action: .passThrough)
        )

        let resolved = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled)

        #expect(resolved.interceptedButtons.isEmpty)
        #expect(resolved.issues.isEmpty)
    }

    @Test("buttons the device does not divert stay native and are reported")
    func invalidButtonForDevice() throws {
        let mappings = try Self.set(ButtonMapping(trigger: .press(.sensePanel), action: .media(.playPause)))

        let resolved = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled)

        #expect(resolved.issues == [.triggerUnavailable(.press(.sensePanel))])
        #expect(resolved.interceptedButtons.isEmpty)
    }

    @Test("swipes need directional gesture support on diverted buttons")
    func swipeRequiresGestureCapability() throws {
        let mappings = try Self.set(ButtonMapping(trigger: .swipe(.modeShift, .up), action: .media(.volumeUp)))

        let resolved = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled)

        #expect(resolved.issues == [.triggerUnavailable(.swipe(.modeShift, .up))])
    }

    @Test("swipes on system-reported buttons only need the button")
    func swipeOnSystemButton() throws {
        let mappings = try Self.set(ButtonMapping(trigger: .swipe(.middle, .down), action: .system(.showDesktop)))

        let resolved = MappingResolver.resolve(mappings, capabilities: .undiscovered, mode: .enabled)

        #expect(resolved.issues.isEmpty)
        #expect(resolved.swipeButtons == [.middle])
        #expect(resolved.buttonsRequiringDiversion.isEmpty)
    }

    @Test(
        "device actions need the matching capability",
        arguments: [
            (
                DeviceAction.cycleResolutionPresets, MouseCapabilities(resolution: .unsupported),
                Availability.unavailable
            ),
            (.toggleSmartShift, MouseCapabilities(smartShift: .unsupported), .unavailable),
            (.toggleScrollMode, MouseCapabilities.undiscovered, .pending),
        ]
    )
    func deviceActionCapabilities(action: DeviceAction, capabilities: MouseCapabilities, expected: Availability) throws
    {
        let mappings = try Self.set(ButtonMapping(trigger: .press(.middle), action: .device(action)))

        let resolved = MappingResolver.resolve(mappings, capabilities: capabilities, mode: .enabled)

        #expect(resolved.issues == [.actionRequiresCapability(.press(.middle), action, expected)])
        #expect(resolved.action(for: .press(.middle)) == .passThrough)
    }

    @Test("unknown actions are reported and stay native")
    func unsupportedAction() throws {
        let mappings = try Self.set(
            ButtonMapping(trigger: .press(.back), action: .unsupported(UnsupportedAction(identifier: "future_action")))
        )

        let resolved = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled)

        #expect(resolved.issues == [.unsupportedAction(.press(.back), identifier: "future_action")])
        #expect(resolved.interceptedButtons.isEmpty)
    }

    @Test("mappings activate when capabilities are discovered and deactivate when lost")
    func capabilityChanges() throws {
        let mappings = try Self.set(ButtonMapping(trigger: .press(.gesture), action: .system(.appExpose)))

        let before = MappingResolver.resolve(mappings, capabilities: .undiscovered, mode: .enabled)
        let after = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled)
        let lost = MappingResolver.resolve(
            mappings,
            capabilities: Self.gestureMouse.refined(by: MouseCapabilities(divertableButtons: .unsupported)),
            mode: .enabled
        )

        #expect(before.issues == [.triggerPending(.press(.gesture))])
        #expect(before.interceptedButtons.isEmpty)
        #expect(after.action(for: .press(.gesture)) == .system(.appExpose))
        #expect(lost.issues == [.triggerUnavailable(.press(.gesture))])
        #expect(lost.buttonsRequiringDiversion.isEmpty)
    }

    @Test("switching profiles intercepts exactly the new profile's triggers")
    func profileTransitions() throws {
        let safari = ProfileFixtures.app("com.apple.Safari")
        let defaults = try Self.set(ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)))
        let profile = ProfileFixtures.profile(
            "safari",
            apps: [safari],
            overrides: [
                ButtonMapping(trigger: .press(.back), action: .passThrough),
                ButtonMapping(trigger: .press(.gesture), action: .shortcut(.newTab)),
            ]
        )
        let profiles = try ProfileSet(defaultMappings: defaults, applicationProfiles: [profile])

        let inDefault = MappingResolver.resolve(
            profiles.effectiveMappings(for: .defaultProfile),
            capabilities: Self.gestureMouse,
            mode: .enabled
        )
        let inSafari = MappingResolver.resolve(
            profiles.effectiveMappings(for: .application(profile.id)),
            capabilities: Self.gestureMouse,
            mode: .enabled
        )

        #expect(inDefault.interceptedButtons == [.back])
        #expect(inSafari.interceptedButtons == [.gesture])
        #expect(inSafari.action(for: .press(.back)) == .passThrough)
    }

    @Test("conflicting mappings for one trigger are rejected before resolution")
    func conflictingMappings() {
        #expect(throws: MappingRejection.duplicateTrigger(.swipe(.gesture, .up))) {
            try Self.set(
                ButtonMapping(trigger: .swipe(.gesture, .up), action: .system(.missionControl)),
                ButtonMapping(trigger: .swipe(.gesture, .up), action: .system(.launchpad))
            )
        }
    }

    @Test("horizontal scrolling can be mapped without device capabilities")
    func horizontalScroll() throws {
        let mappings = try Self.set(ButtonMapping(trigger: .horizontalScroll(.left), action: .system(.previousSpace)))

        let resolved = MappingResolver.resolve(mappings, capabilities: .undiscovered, mode: .enabled)

        #expect(resolved.action(for: .horizontalScroll(.left)) == .system(.previousSpace))
        #expect(resolved.interceptedButtons.isEmpty)
    }

    @Test("issues are reported in a stable order")
    func deterministicIssues() throws {
        let mappings = try Self.set(
            ButtonMapping(trigger: .press(.thumb), action: .media(.mute)),
            ButtonMapping(trigger: .press(.dpiSwitch), action: .media(.mute)),
            ButtonMapping(trigger: .swipe(.sensePanel, .up), action: .media(.mute))
        )

        let issues = MappingResolver.resolve(mappings, capabilities: Self.gestureMouse, mode: .enabled).issues

        #expect(
            issues == [
                .triggerUnavailable(.press(.dpiSwitch)),
                .triggerUnavailable(.press(.thumb)),
                .triggerUnavailable(.swipe(.sensePanel, .up)),
            ]
        )
    }
}
