public import LogiDuoDomain

/// The single owner of the configuration in memory, with debounced durable saves.
///
/// Changes apply immediately and are broadcast; saving waits `delay` after the last
/// change so a burst of edits (dragging a slider) causes one write. ``flush()``
/// saves at once (call it before the app quits).
public actor ConfigurationRepository<SaveClock: Clock>: ConfigurationRepositing where SaveClock.Duration == Duration {
    private let store: any ConfigurationStoring
    private let clock: SaveClock
    private let delay: Duration
    private var configuration: LogiDuoConfiguration
    private var pendingSave: Task<Void, Never>?
    private var generation = 0
    private var subscribers: [Int: AsyncStream<LogiDuoConfiguration>.Continuation] = [:]
    private var nextSubscriber = 0

    /// How loading went.
    public let loadStatus: ConfigurationLoadStatus
    /// The configuration as loaded at launch, readable synchronously (for launch decisions).
    nonisolated public let launchConfiguration: LogiDuoConfiguration
    /// The last save failure, if any.
    public private(set) var lastSaveError: ConfigurationStoreError?
    /// How many saves reached the store.
    public private(set) var saveCount = 0

    /// Loads the configuration from `store`.
    public init(store: any ConfigurationStoring, clock: SaveClock, delay: Duration = .milliseconds(500)) {
        let loaded = store.load()
        self.store = store
        self.clock = clock
        self.delay = delay
        configuration = loaded.configuration
        launchConfiguration = loaded.configuration
        loadStatus = loaded.status
    }

    /// The current configuration.
    public func current() -> LogiDuoConfiguration { configuration }

    /// Why changes are not being saved, if they are not.
    public func saveProblem() -> ConfigurationSaveProblem? {
        switch loadStatus {
        case .newerVersion: return .newerVersion
        case .unreadable: return .unreadable
        case .recovered: return lastSaveError == nil ? .recoveredFromCorruption : .saveFailed
        case .fresh, .loaded: return lastSaveError == nil ? nil : .saveFailed
        }
    }

    /// Applies `change`, broadcasts it and schedules a save.
    public func update(_ change: @Sendable (inout LogiDuoConfiguration) -> Void) {
        var updated = configuration
        change(&updated)
        guard updated != configuration else { return }
        configuration = updated
        for subscriber in subscribers.values { subscriber.yield(updated) }
        scheduleSave()
    }

    /// Every configuration after a change, starting with the current one.
    public func updates() -> AsyncStream<LogiDuoConfiguration> {
        let (stream, continuation) = AsyncStream.makeStream(of: LogiDuoConfiguration.self)
        let id = nextSubscriber
        nextSubscriber += 1
        subscribers[id] = continuation
        continuation.yield(configuration)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    /// Saves now if a save is pending.
    public func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    private func unsubscribe(_ id: Int) {
        subscribers[id] = nil
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        generation += 1
        let scheduled = generation
        let clock = clock
        let delay = delay
        pendingSave = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.saveIfLatest(scheduled)
        }
    }

    /// Saves only for the latest scheduled change; earlier timers are superseded.
    private func saveIfLatest(_ scheduled: Int) {
        guard scheduled == generation, pendingSave != nil else { return }
        pendingSave = nil
        save()
    }

    private func save() {
        guard loadStatus.isWritable else {
            lastSaveError = .readOnly
            return
        }
        do {
            try store.save(configuration)
            saveCount += 1
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }
}
