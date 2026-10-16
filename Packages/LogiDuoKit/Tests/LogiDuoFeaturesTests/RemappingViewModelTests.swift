import LogiDuoDomain
import LogiDuoFeatures
import Testing

@MainActor
final class FakeRemappingService: RemappingService {
    var status = RemappingStatus.off
    let statusUpdates: AsyncStream<RemappingStatus>
    let sink: AsyncStream<RemappingStatus>.Continuation
    var openedSettings = 0
    var nextNotice: RemappingNotice?

    init() {
        (statusUpdates, sink) = AsyncStream.makeStream()
    }

    func setEnabled(_ enabled: Bool) {
        status.isEnabled = enabled
        status.isIntercepting = enabled && nextNotice == nil
        status.notice = enabled ? nextNotice : nil
    }

    func select(_ preset: ValidationPreset) { status.preset = preset }
    func openPermissionSettings() { openedSettings += 1 }
}

@MainActor
@Suite("RemappingViewModel")
struct RemappingViewModelTests {
    @Test("starts off and describes native input")
    func startsOff() {
        let model = RemappingViewModel(service: FakeRemappingService())
        #expect(!model.isEnabled)
        #expect(model.statusKey == "remapping.status.off")
        #expect(!model.offersPermissionSettings)
    }

    @Test("toggling forwards to the service and reflects interception")
    func toggles() {
        let service = FakeRemappingService()
        let model = RemappingViewModel(service: service)

        model.isEnabled = true
        #expect(model.statusKey == "remapping.status.on")
        model.isEnabled = false
        #expect(model.statusKey == "remapping.status.off")
    }

    @Test("a missing permission offers the settings button")
    func permissionNotice() {
        let service = FakeRemappingService()
        service.nextNotice = .accessibilityRequired
        let model = RemappingViewModel(service: service)

        model.setEnabled(true)
        #expect(model.statusKey == "remapping.status.needsAccessibility")
        #expect(model.offersPermissionSettings)
        model.openPermissionSettings()
        #expect(service.openedSettings == 1)
    }

    @Test("the fail-safe stop is described")
    func stopped() {
        let service = FakeRemappingService()
        service.nextNotice = .stoppedAfterRepeatedTimeouts
        let model = RemappingViewModel(service: service)
        model.setEnabled(true)
        #expect(model.statusKey == "remapping.status.stopped")
    }

    @Test("status updates from the service reach the model")
    func observesUpdates() async {
        let service = FakeRemappingService()
        let model = RemappingViewModel(service: service)
        let observing = Task { await model.observe() }

        service.sink.yield(
            RemappingStatus(isEnabled: true, isIntercepting: true, preset: .backToMissionControl, notice: nil)
        )
        service.sink.finish()
        await observing.value

        #expect(model.status.preset == .backToMissionControl)
        #expect(model.statusKey == "remapping.status.on")
    }

    @Test("every validation preset is valid and touches at most one button")
    func presets() {
        for preset in ValidationPreset.allCases {
            #expect(preset.mappings.mappings.count <= 1)
        }
        #expect(ValidationPreset.observeOnly.mappings.mappings.isEmpty)
    }
}
