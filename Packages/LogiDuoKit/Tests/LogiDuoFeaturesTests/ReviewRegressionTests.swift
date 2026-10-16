import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoFeatures

@MainActor
@Suite("Review regressions (features)")
struct ReviewRegressionTests {
    @Test("regression: deleting works even when the dialog cleared its pending state first")
    func deleteAfterDismissal() async {
        var configuration = LogiDuoConfiguration.standard
        configuration.profiles = [
            StoredProfile(
                id: ProfileFixtures.id("a"),
                name: ProfileFixtures.name("A"),
                matchers: [ProfileFixtures.app("com.a")]
            )
        ]
        let repository = FakeConfigurationRepository(configuration)
        let model = ProfilesViewModel(repository: repository)
        let observing = Task { await model.observe() }
        await repository.finish()
        await observing.value

        model.requestDeletion(ProfileFixtures.id("a"))
        let confirmed = model.pendingDeletion
        model.cancelDeletion()  // what SwiftUI's isPresented setter does on dismissal
        await model.delete(confirmed)

        #expect(await repository.current().profiles.isEmpty)
    }

    @Test("regression: a default-profile edit that would break an application profile is refused")
    func defaultEditBreakingProfile() async {
        var configuration = LogiDuoConfiguration.standard
        configuration.profiles = [
            StoredProfile(
                id: ProfileFixtures.id("a"),
                name: ProfileFixtures.name("A"),
                matchers: [ProfileFixtures.app("com.a")],
                mappings: [ButtonMapping(trigger: .press(.forward), action: .click(.back))]
            )
        ]
        let repository = FakeConfigurationRepository(configuration)
        let model = MappingEditorViewModel(repository: repository)
        let observing = Task { await model.observe() }
        await repository.finish()
        await observing.value

        await model.setAction(.click(.forward), for: .press(.back))

        guard case .clickCycle = model.lastRejection else {
            Issue.record("expected a click-loop rejection, got \(String(describing: model.lastRejection))")
            return
        }
        #expect(await repository.current().defaultMappings.isEmpty)
    }

    @Test("save problems are shown in the editor")
    func saveProblem() async {
        let repository = FakeConfigurationRepository()
        await repository.setProblem(.newerVersion)
        let model = MappingEditorViewModel(repository: repository)
        let observing = Task { await model.observe() }
        await repository.finish()
        await observing.value
        #expect(model.saveProblem == .newerVersion)
    }
}
