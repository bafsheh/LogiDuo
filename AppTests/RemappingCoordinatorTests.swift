import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoSystem
import Testing

@testable import LogiDuo

final class AppFakeTapBackend: EventTapBackend, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var handler: EventTapHandler?
    private(set) var installs = 0

    var isInstalled: Bool { lock.withLock { handler != nil } }

    func install(mask: CGEventMask, handler: @escaping EventTapHandler) -> Bool {
        lock.withLock {
            installs += 1
            self.handler = handler
            return true
        }
    }

    func reenable() {}
    func remove() { lock.withLock { handler = nil } }

    func deliver(_ type: CGEventType, button: Int64) -> CGEvent? {
        guard
            let handler = lock.withLock({ self.handler }),
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: .zero,
                mouseButton: .center
            )
        else { return nil }
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return handler(type, event)
    }
}

final class AppFakeChecker: PermissionChecking, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var accessibility: PermissionStatus
    private(set) var prompts = 0

    init(_ accessibility: PermissionStatus) { self.accessibility = accessibility }
    func grant() { lock.withLock { accessibility = .granted } }
    func status(of kind: PermissionKind) -> PermissionStatus {
        lock.withLock { kind == .accessibility ? accessibility : .granted }
    }
    func requestPrompt(for kind: PermissionKind) { lock.withLock { prompts += 1 } }
}

final class AppRecordingExecutor: InputCommandPerforming, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var log: [InputCommand] = []
    var commands: [InputCommand] { lock.withLock { log } }
    func perform(_ commands: [InputCommand]) { lock.withLock { log += commands } }
}

@MainActor
@Suite("RemappingCoordinator", .serialized)
struct RemappingCoordinatorTests {
    private struct Harness {
        let coordinator: RemappingCoordinator
        let backend: AppFakeTapBackend
        let checker: AppFakeChecker
        let executor: AppRecordingExecutor
        let engine: LiveInputEngine
    }

    private func makeHarness(
        accessibility: PermissionStatus = .granted,
        capabilities: MouseCapabilities = .undiscovered
    ) -> Harness {
        let backend = AppFakeTapBackend()
        let checker = AppFakeChecker(accessibility)
        let executor = AppRecordingExecutor()
        let engine = LiveInputEngine(backend: backend, executor: executor)
        let coordinator = RemappingCoordinator(
            engine: engine,
            checker: checker,
            permissionMonitor: PermissionMonitor(checker: checker, clock: ContinuousClock()),
            capabilities: capabilities,
            openURL: { _ in }
        )
        return Harness(coordinator: coordinator, backend: backend, checker: checker, executor: executor, engine: engine)
    }

    @Test("remapping is off at launch and no event tap exists")
    func offAtLaunch() {
        let harness = makeHarness()
        #expect(harness.coordinator.status == .off)
        #expect(harness.backend.installs == 0)
    }

    @Test("enabling with permission installs the tap and applies the preset")
    func enableWithPermission() {
        let harness = makeHarness()
        harness.coordinator.select(.forwardToMiddleClick)
        harness.coordinator.setEnabled(true)

        #expect(harness.coordinator.status.isIntercepting)
        #expect(harness.backend.deliver(.otherMouseDown, button: 4) == nil)
        #expect(harness.backend.deliver(.otherMouseUp, button: 4) == nil)
        harness.engine.drainCommands()
        #expect(harness.executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
    }

    @Test("configured mappings follow the active profile while remapping is on")
    func configuredProfile() throws {
        let harness = makeHarness()
        harness.coordinator.setEnabled(true)
        let mappings = try MappingSet([ButtonMapping(trigger: .press(.forward), action: .click(.middle))])
        guard let id = ProfileID(rawValue: "safari") else { return }

        harness.coordinator.apply(ActiveProfile(selection: .application(id), name: "Safari", mappings: mappings))

        #expect(harness.coordinator.status.activeProfileName == "Safari")
        #expect(harness.backend.deliver(.otherMouseDown, button: 4) == nil)
        #expect(harness.backend.deliver(.otherMouseUp, button: 4) == nil)
        harness.engine.drainCommands()
        #expect(harness.executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])

        harness.coordinator.apply(.none)
        #expect(harness.coordinator.status.activeProfileName == nil)
        #expect(harness.backend.deliver(.otherMouseDown, button: 4) != nil)
    }

    @Test("with diversion authorized, a gesture-button mapping diverts the button and runs its action")
    func gestureButtonMapping() throws {
        let harness = makeHarness(capabilities: AppCompositionRoot.mouseCapabilities)
        var diverted: [Set<MouseButton>] = []
        harness.coordinator.diversionChanged = { diverted.append($0) }
        harness.coordinator.setEnabled(true)
        let mappings = try MappingSet([ButtonMapping(trigger: .press(.gesture), action: .click(.middle))])

        harness.coordinator.apply(ActiveProfile(selection: .defaultProfile, name: nil, mappings: mappings))
        harness.coordinator.deviceInput(.buttonDown(.gesture))
        harness.coordinator.deviceInput(.buttonUp(.gesture))
        harness.engine.drainCommands()

        #expect(diverted.last == [.gesture])
        #expect(harness.executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
    }

    @Test("without diversion, a gesture-button mapping asks for nothing and does nothing")
    func gestureButtonWithoutDiversion() throws {
        let harness = makeHarness()
        var diverted: [Set<MouseButton>] = []
        harness.coordinator.diversionChanged = { diverted.append($0) }
        harness.coordinator.setEnabled(true)
        let mappings = try MappingSet([ButtonMapping(trigger: .press(.gesture), action: .click(.middle))])

        harness.coordinator.apply(ActiveProfile(selection: .defaultProfile, name: nil, mappings: mappings))
        harness.coordinator.deviceInput(.buttonDown(.gesture))
        harness.coordinator.deviceInput(.buttonUp(.gesture))
        harness.engine.drainCommands()

        let divertedAnything = diverted.contains { !$0.isEmpty }
        #expect(!divertedAnything)
        #expect(harness.executor.commands.isEmpty)
    }

    @Test("a validation preset overrides the profile until switched back")
    func presetOverridesProfile() throws {
        let harness = makeHarness()
        harness.coordinator.setEnabled(true)
        let mappings = try MappingSet([ButtonMapping(trigger: .press(.forward), action: .click(.middle))])
        harness.coordinator.apply(ActiveProfile(selection: .defaultProfile, name: nil, mappings: mappings))

        harness.coordinator.select(.observeOnly)
        #expect(harness.backend.deliver(.otherMouseDown, button: 4) != nil)
        #expect(harness.backend.deliver(.otherMouseUp, button: 4) != nil)

        harness.coordinator.select(.configured)
        #expect(harness.backend.deliver(.otherMouseDown, button: 4) == nil)
    }

    @Test("turning remapping on or off is reported for persistence")
    func reportsEnabled() {
        let harness = makeHarness()
        var reported: [Bool] = []
        harness.coordinator.enabledChanged = { reported.append($0) }
        harness.coordinator.setEnabled(true)
        harness.coordinator.setEnabled(false)
        #expect(reported == [true, false])
    }

    @Test("without Accessibility, enabling prompts once per launch and never installs the tap")
    func enableWithoutPermission() {
        let harness = makeHarness(accessibility: .denied)
        harness.coordinator.setEnabled(true)
        #expect(harness.coordinator.status.notice == .accessibilityRequired)
        #expect(!harness.coordinator.status.isIntercepting)

        harness.coordinator.setEnabled(false)
        harness.coordinator.setEnabled(true)
        #expect(harness.checker.prompts == 1)
        #expect(harness.backend.installs == 0)
    }

    @Test("permission granted later starts interception without another prompt")
    func permissionGrantedLater() {
        let harness = makeHarness(accessibility: .denied)
        harness.coordinator.setEnabled(true)
        harness.checker.grant()

        harness.coordinator.permissionsChanged([.accessibility: .granted, .inputMonitoring: .granted])

        #expect(harness.coordinator.status.isIntercepting)
        #expect(harness.coordinator.status.notice == nil)
        #expect(harness.checker.prompts == 1)
    }

    @Test("revoked permission stops interception and restores native input")
    func permissionRevoked() {
        let harness = makeHarness()
        harness.coordinator.select(.forwardToMiddleClick)
        harness.coordinator.setEnabled(true)
        _ = harness.backend.deliver(.otherMouseDown, button: 4)

        harness.coordinator.permissionsChanged([.accessibility: .denied, .inputMonitoring: .granted])
        harness.engine.drainCommands()

        #expect(!harness.backend.isInstalled)
        #expect(harness.coordinator.status.notice == .accessibilityRequired)
        #expect(harness.executor.commands.last == .releaseSynthetic(.middle))
    }

    @Test("disabling removes the tap; quitting mid-press releases the synthetic button")
    func disableAndShutdown() {
        let harness = makeHarness()
        harness.coordinator.select(.forwardToMiddleClick)
        harness.coordinator.setEnabled(true)
        _ = harness.backend.deliver(.otherMouseDown, button: 4)

        harness.coordinator.shutdown()

        #expect(!harness.backend.isInstalled)
        #expect(
            harness.coordinator.status
                == RemappingStatus(isEnabled: false, isIntercepting: false, preset: .forwardToMiddleClick, notice: nil)
        )
        #expect(harness.executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
        #expect(harness.backend.deliver(.otherMouseUp, button: 4) == nil)
    }

    @Test("going to sleep releases a held synthetic button but keeps remapping on")
    func sleepReleasesHeldInput() {
        let harness = makeHarness()
        harness.coordinator.select(.forwardToMiddleClick)
        harness.coordinator.setEnabled(true)
        _ = harness.backend.deliver(.otherMouseDown, button: 4)

        harness.coordinator.hostWillSleep()

        #expect(harness.executor.commands == [.pressSynthetic(.middle), .releaseSynthetic(.middle)])
        #expect(harness.coordinator.status.isIntercepting)
    }
}
