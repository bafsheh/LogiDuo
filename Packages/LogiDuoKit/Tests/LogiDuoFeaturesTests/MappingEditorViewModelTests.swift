import LogiDuoDomain
import LogiDuoTestSupport
import SwiftUI
import Testing

@testable import LogiDuoFeatures

/// An in-memory configuration owner.
actor FakeConfigurationRepository: ConfigurationRepositing {
    private var configuration: LogiDuoConfiguration
    private var subscribers: [AsyncStream<LogiDuoConfiguration>.Continuation] = []
    private(set) var updateCount = 0
    private var finished = false

    init(_ configuration: LogiDuoConfiguration = .standard) {
        self.configuration = configuration
    }

    func current() -> LogiDuoConfiguration { configuration }

    func update(_ change: @Sendable (inout LogiDuoConfiguration) -> Void) {
        change(&configuration)
        updateCount += 1
        for subscriber in subscribers { subscriber.yield(configuration) }
    }

    func updates() -> AsyncStream<LogiDuoConfiguration> {
        let (stream, continuation) = AsyncStream.makeStream(of: LogiDuoConfiguration.self)
        continuation.yield(configuration)
        if finished {
            continuation.finish()
        } else {
            subscribers.append(continuation)
        }
        return stream
    }

    /// Ends every subscription, including ones made later.
    func finish() {
        finished = true
        for subscriber in subscribers { subscriber.finish() }
    }
}

@MainActor
@Suite("MappingEditorViewModel")
struct MappingEditorViewModelTests {
    private static let safariID = ProfileFixtures.id("safari")

    private static func loaded(
        _ configuration: LogiDuoConfiguration = .standard
    ) async -> (MappingEditorViewModel, FakeConfigurationRepository) {
        let repository = FakeConfigurationRepository(configuration)
        let model = MappingEditorViewModel(repository: repository)
        let observing = Task { await model.observe() }
        await repository.finish()
        await observing.value
        return (model, repository)
    }

    private static var withSafari: LogiDuoConfiguration {
        var configuration = LogiDuoConfiguration.standard
        configuration.defaultMappings = [ButtonMapping(trigger: .press(.back), action: .system(.missionControl))]
        configuration.profiles = [
            StoredProfile(
                id: safariID,
                name: ProfileFixtures.name("Safari"),
                matchers: [ProfileFixtures.app("com.apple.Safari")]
            )
        ]
        return configuration
    }

    @Test("rows show native buttons, and buttons needing device access are flagged")
    func rows() async {
        let (model, _) = await Self.loaded()
        let buttons = model.rows(in: .buttons)
        #expect(
            buttons.map(\.trigger) == [
                .press(.middle), .press(.back), .press(.forward), .press(.gesture), .press(.modeShift),
            ]
        )
        #expect(buttons.allSatisfy { $0.source == .native && $0.action == .passThrough })
        #expect(buttons.filter(\.needsDeviceAccess).map(\.trigger) == [.press(.gesture), .press(.modeShift)])
        #expect(model.rows(in: .scrolling).count == 2)
    }

    @Test("setting an action saves it to the default profile")
    func setDefault() async {
        let (model, repository) = await Self.loaded()
        await model.setAction(.media(.playPause), for: .press(.middle))

        #expect(
            await repository.current().defaultMappings == [
                ButtonMapping(trigger: .press(.middle), action: .media(.playPause))
            ]
        )
        #expect(model.rows(in: .buttons).first?.source == .profile)
    }

    @Test("choosing Default in the default profile removes the mapping")
    func clearDefault() async {
        let (model, repository) = await Self.loaded(Self.withSafari)
        await model.setAction(.passThrough, for: .press(.back))
        #expect(await repository.current().defaultMappings.isEmpty)
    }

    @Test("an application profile inherits, overrides and can reset to the default")
    func applicationProfile() async {
        let (model, repository) = await Self.loaded(Self.withSafari)
        model.profile = .application(Self.safariID)

        let back = model.rows(in: .buttons).first { $0.trigger == .press(.back) }
        #expect(back?.source == .inherited)
        #expect(back?.action == .system(.missionControl))

        await model.setAction(.passThrough, for: .press(.back))
        #expect(
            await repository.current().profiles.first?.mappings == [
                ButtonMapping(trigger: .press(.back), action: .passThrough)
            ]
        )

        await model.resetToInherited(.press(.back))
        #expect(await repository.current().profiles.first?.mappings.isEmpty == true)
    }

    @Test("a click loop is refused and not saved")
    func rejectsCycle() async {
        var configuration = LogiDuoConfiguration.standard
        configuration.defaultMappings = [ButtonMapping(trigger: .press(.back), action: .click(.forward))]
        let (model, repository) = await Self.loaded(configuration)

        await model.setAction(.click(.back), for: .press(.forward))

        #expect(
            model.lastRejection == .clickCycle([.back, .forward])
                || model.lastRejection == .clickCycle([.forward, .back])
        )
        #expect(await repository.current().defaultMappings.count == 1)
    }

    @Test("a button mapped to click itself is refused")
    func rejectsSelfClick() async {
        let (model, repository) = await Self.loaded()
        await model.setAction(.click(.middle), for: .press(.middle))
        #expect(model.lastRejection == .selfReferential(.press(.middle)))
        #expect(await repository.updateCount == 0)
    }

    @Test("gesture rows follow the chosen button")
    func gestureRows() async {
        let (model, _) = await Self.loaded()
        model.gestureButton = .back
        #expect(model.rows(in: .gestures).map(\.trigger) == SwipeDirection.allCases.map { .swipe(.back, $0) })
    }

    @Test("custom shortcuts are captured from key presses, including special keys")
    func capture() {
        #expect(ShortcutCapture.shortcut(for: "c", modifiers: .command)?.displayString == "⌘C")
        #expect(ShortcutCapture.shortcut(for: .upArrow, modifiers: [.control, .option])?.displayString == "⌃⌥↑")
        #expect(ShortcutCapture.shortcut(for: "é", modifiers: []) == nil)
        #expect(ShortcutCapture.functionKeys.count == 20)
    }
}
