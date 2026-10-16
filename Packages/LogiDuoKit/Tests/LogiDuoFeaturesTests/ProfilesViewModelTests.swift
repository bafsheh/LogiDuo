import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoFeatures

@MainActor
@Suite("ProfilesViewModel")
struct ProfilesViewModelTests {
    private static let safari = ProfileFixtures.bundle("com.apple.Safari")
    private static let mail = ProfileFixtures.bundle("com.apple.mail")

    private static func loaded(
        _ configuration: LogiDuoConfiguration = .standard
    ) async -> (ProfilesViewModel, FakeConfigurationRepository) {
        let repository = FakeConfigurationRepository(configuration)
        let model = ProfilesViewModel(repository: repository)
        let observing = Task { await model.observe() }
        await repository.finish()
        await observing.value
        return (model, repository)
    }

    @Test("adding an application creates and selects its profile; adding it again selects the existing one")
    func add() async {
        let (model, repository) = await Self.loaded()
        await model.add(application: Self.safari, name: "Safari")
        await model.add(application: Self.safari, name: "Safari again")

        #expect(await repository.current().profiles.map(\.name.value) == ["Safari"])
        #expect(model.selection?.rawValue == "app.com.apple.Safari")
    }

    @Test("rename ignores blank names; enable toggles")
    func edit() async {
        let (model, repository) = await Self.loaded()
        await model.add(application: Self.safari, name: "Safari")
        let id = ProfileFixtures.id("app.com.apple.Safari")

        await model.rename(id, to: "  ")
        await model.rename(id, to: "Browsing")
        await model.setEnabled(id, false)

        let stored = await repository.current().profiles.first
        #expect(stored?.name.value == "Browsing")
        #expect(stored?.isEnabled == false)
    }

    @Test("moving changes priority order")
    func move() async {
        let (model, repository) = await Self.loaded()
        await model.add(application: Self.safari, name: "Safari")
        await model.add(application: Self.mail, name: "Mail")

        await model.move(ProfileFixtures.id("app.com.apple.mail"), up: true)
        await model.move(ProfileFixtures.id("app.com.apple.mail"), up: true)

        #expect(await repository.current().profiles.map(\.name.value) == ["Mail", "Safari"])
    }

    @Test("delete happens only after confirmation; cancelling keeps the profile")
    func delete() async {
        let (model, repository) = await Self.loaded()
        await model.add(application: Self.safari, name: "Safari")
        let id = ProfileFixtures.id("app.com.apple.Safari")

        model.requestDeletion(id)
        model.cancelDeletion()
        #expect(await repository.current().profiles.count == 1)

        model.requestDeletion(id)
        await model.confirmDeletion()
        #expect(await repository.current().profiles.isEmpty)
        #expect(model.selection == nil)
    }
}
