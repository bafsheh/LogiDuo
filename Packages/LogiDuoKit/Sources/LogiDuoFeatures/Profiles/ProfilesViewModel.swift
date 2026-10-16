public import LogiDuoDomain
public import Observation

/// Presentation state and intents for managing application profiles.
@MainActor
@Observable
public final class ProfilesViewModel {
    /// Application profiles, in priority order (first match wins).
    public private(set) var profiles: [StoredProfile] = []
    /// The profile shown in the detail area.
    public var selection: ProfileID?
    /// A profile waiting for delete confirmation.
    public var pendingDeletion: StoredProfile?

    private let repository: any ConfigurationRepositing

    /// Creates a view model.
    public init(repository: any ConfigurationRepositing) {
        self.repository = repository
    }

    /// The selected profile.
    public var selected: StoredProfile? {
        profiles.first { $0.id == selection }
    }

    /// Adds a profile for an application, or selects the one that already covers it.
    public func add(application: BundleIdentifier, name: String) async {
        switch ProfileFactory.profile(for: application, name: name, existing: profiles) {
        case .existing(let id):
            selection = id
        case .created(let profile):
            profiles.append(profile)
            selection = profile.id
            await repository.update { $0.profiles.append(profile) }
        }
    }

    /// Renames a profile; blank names are ignored.
    public func rename(_ id: ProfileID, to name: String) async {
        guard let validated = ProfileName(name) else { return }
        await edit(id) { $0.name = validated }
    }

    /// Enables or disables a profile.
    public func setEnabled(_ id: ProfileID, _ enabled: Bool) async {
        await edit(id) { $0.isEnabled = enabled }
    }

    /// Moves a profile one place up (higher priority) or down.
    public func move(_ id: ProfileID, up: Bool) async {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard profiles.indices.contains(target) else { return }
        profiles.swapAt(index, target)
        let ordered = profiles.map(\.id)
        await repository.update { configuration in
            configuration.profiles.sort { lhs, rhs in
                (ordered.firstIndex(of: lhs.id) ?? .max) < (ordered.firstIndex(of: rhs.id) ?? .max)
            }
        }
    }

    /// Asks for confirmation before deleting.
    public func requestDeletion(_ id: ProfileID) {
        pendingDeletion = profiles.first { $0.id == id }
    }

    /// Deletes the profile awaiting confirmation.
    public func confirmDeletion() async {
        await delete(pendingDeletion)
    }

    /// Deletes `profile` (the one the person confirmed).
    public func delete(_ profile: StoredProfile?) async {
        guard let profile else { return }
        pendingDeletion = nil
        profiles.removeAll { $0.id == profile.id }
        if selection == profile.id { selection = profiles.first?.id }
        let id = profile.id
        await repository.update { $0.profiles.removeAll { $0.id == id } }
    }

    /// Keeps the profile.
    public func cancelDeletion() {
        pendingDeletion = nil
    }

    /// Follows configuration changes until the calling task is cancelled.
    public func observe() async {
        for await configuration in await repository.updates() {
            profiles = configuration.profiles
            if let selection, !profiles.contains(where: { $0.id == selection }) { self.selection = profiles.first?.id }
            if selection == nil { selection = profiles.first?.id }
        }
    }

    private func edit(_ id: ProfileID, _ change: @escaping @Sendable (inout StoredProfile) -> Void) async {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[index])
        await repository.update { configuration in
            if let index = configuration.profiles.firstIndex(where: { $0.id == id }) {
                change(&configuration.profiles[index])
            }
        }
    }
}
