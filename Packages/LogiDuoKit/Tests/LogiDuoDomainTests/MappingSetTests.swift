import LogiDuoDomain
import Testing

@Suite("MappingSet")
struct MappingSetTests {
    @Test("unmapped triggers pass through")
    func defaultIsPassThrough() {
        #expect(MappingSet.empty.action(for: .press(.middle)) == .passThrough)
        #expect(MappingSet.empty.action(for: .horizontalScroll(.left)) == .passThrough)
    }

    @Test("returns the mapped action for a trigger")
    func mappedAction() throws {
        let set = try MappingSet([
            ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)),
            ButtonMapping(trigger: .swipe(.gesture, .up), action: .system(.missionControl)),
        ])

        #expect(set.action(for: .press(.back)) == .shortcut(.browserBack))
        #expect(set.action(for: .swipe(.gesture, .up)) == .system(.missionControl))
        #expect(set.action(for: .swipe(.gesture, .down)) == .passThrough)
    }

    @Test("a disabled mapping behaves natively but is kept")
    func disabledMapping() throws {
        let mapping = ButtonMapping(trigger: .press(.forward), action: .media(.playPause), isEnabled: false)
        let set = try MappingSet([mapping])

        #expect(set.action(for: .press(.forward)) == .passThrough)
        #expect(set.mappings[.press(.forward)] == mapping)
    }

    @Test(
        "protected buttons cannot be triggers",
        arguments: [
            InputTrigger.press(.primary), .press(.secondary), .swipe(.primary, .left), .swipe(.secondary, .up),
        ]
    )
    func protectedTriggers(trigger: InputTrigger) {
        #expect(throws: MappingRejection.protectedTrigger(trigger)) {
            try MappingSet([ButtonMapping(trigger: trigger, action: .media(.mute))])
        }
    }

    @Test("protected buttons can still be the target of a synthetic click")
    func clickPrimaryAllowed() throws {
        let set = try MappingSet([ButtonMapping(trigger: .press(.gesture), action: .click(.primary))])
        #expect(set.action(for: .press(.gesture)) == .click(.primary))
    }

    @Test("rejects a mapping that clicks its own button")
    func selfReferential() {
        #expect(throws: MappingRejection.selfReferential(.press(.back))) {
            try MappingSet([ButtonMapping(trigger: .press(.back), action: .click(.back))])
        }
    }

    @Test("a swipe may click the button it is performed with")
    func swipeClickingOwnButton() throws {
        let set = try MappingSet([ButtonMapping(trigger: .swipe(.middle, .down), action: .click(.middle))])
        #expect(set.action(for: .swipe(.middle, .down)) == .click(.middle))
    }

    @Test("rejects duplicate triggers")
    func duplicates() {
        #expect(throws: MappingRejection.duplicateTrigger(.press(.middle))) {
            try MappingSet([
                ButtonMapping(trigger: .press(.middle), action: .media(.mute)),
                ButtonMapping(trigger: .press(.middle), action: .media(.playPause)),
            ])
        }
    }

    @Test("rejects click cycles between buttons")
    func twoButtonCycle() {
        #expect(throws: MappingRejection.clickCycle([.back, .forward])) {
            try MappingSet([
                ButtonMapping(trigger: .press(.back), action: .click(.forward)),
                ButtonMapping(trigger: .press(.forward), action: .click(.back)),
            ])
        }
    }

    @Test("rejects longer click cycles")
    func threeButtonCycle() {
        #expect(throws: MappingRejection.clickCycle([.back, .forward, .middle])) {
            try MappingSet([
                ButtonMapping(trigger: .press(.back), action: .click(.forward)),
                ButtonMapping(trigger: .press(.forward), action: .click(.middle)),
                ButtonMapping(trigger: .press(.middle), action: .click(.back)),
            ])
        }
    }

    @Test("allows click chains that do not loop")
    func acyclicChain() throws {
        let set = try MappingSet([
            ButtonMapping(trigger: .press(.back), action: .click(.forward)),
            ButtonMapping(trigger: .press(.forward), action: .click(.middle)),
        ])
        #expect(set.mappings.count == 2)
    }

    @Test("a disabled mapping does not complete a cycle")
    func disabledBreaksCycle() throws {
        let set = try MappingSet([
            ButtonMapping(trigger: .press(.back), action: .click(.forward)),
            ButtonMapping(trigger: .press(.forward), action: .click(.back), isEnabled: false),
        ])
        #expect(set.action(for: .press(.forward)) == .passThrough)
    }

    @Test("buttons with swipe mappings are reported for tap handling")
    func swipeButtons() throws {
        let set = try MappingSet([
            ButtonMapping(trigger: .swipe(.gesture, .left), action: .system(.previousSpace)),
            ButtonMapping(trigger: .press(.gesture), action: .system(.appExpose)),
            ButtonMapping(trigger: .press(.back), action: .shortcut(.browserBack)),
        ])
        #expect(set.swipeButtons == [.gesture])
    }
}
