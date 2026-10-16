import LogiDuoDomain
import Testing

@testable import LogiDuoFeatures

@MainActor
@Suite("ScrollSettingsViewModel")
struct ScrollSettingsViewModelTests {
    @Test("changes are shown immediately and saved to the scroll settings only")
    func update() async {
        var configuration = LogiDuoConfiguration.standard
        configuration.general.remappingEnabled = true
        let repository = FakeConfigurationRepository(configuration)
        let model = ScrollSettingsViewModel(repository: repository)

        await model.update { $0.invertVertical = true }

        #expect(model.settings.invertVertical)
        let saved = await repository.current()
        #expect(saved.scroll.invertVertical)
        #expect(saved.general.remappingEnabled)
    }
}
