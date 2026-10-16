public import LogiDuoDomain
public import Observation

/// Presentation state and intents for the scroll preferences.
@MainActor
@Observable
public final class ScrollSettingsViewModel {
    /// The current preferences.
    public private(set) var settings = ScrollSettings.standard

    private let repository: any ConfigurationRepositing

    /// Creates a view model.
    public init(repository: any ConfigurationRepositing) {
        self.repository = repository
    }

    /// Changes one preference and saves it.
    public func update(_ change: @escaping @Sendable (inout ScrollSettings) -> Void) async {
        change(&settings)
        await repository.update { change(&$0.scroll) }
    }

    /// Follows configuration changes until the calling task is cancelled.
    public func observe() async {
        for await configuration in await repository.updates() {
            settings = configuration.scroll
        }
    }
}
