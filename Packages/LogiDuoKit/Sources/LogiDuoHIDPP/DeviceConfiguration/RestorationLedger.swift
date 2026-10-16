public import LogiDuoDomain

/// The single owner of the restoration journal: every mutation is saved durably
/// before the call returns, and mutations are serialized.
public actor RestorationLedger {
    /// What loading found.
    public enum LoadOutcome: Hashable, Sendable {
        /// No restoration pending.
        case clean
        /// Restorations from an earlier run are pending (the run did not finish them).
        case pending(entries: Int)
        /// The journal was unreadable and was moved aside; device state is unknown.
        case corrupted
    }

    private let store: any RestorationJournalStoring
    private var journal = RestorationJournal()

    /// Creates a ledger over `store`. Call ``load()`` before use.
    public init(store: any RestorationJournalStoring) {
        self.store = store
    }

    /// Loads the journal from disk.
    public func load() -> LoadOutcome {
        do {
            journal = try store.load()
            return journal.isClean ? .clean : .pending(entries: journal.entries.count)
        } catch {
            journal = RestorationJournal()
            return .corrupted
        }
    }

    /// The journal key of `device`.
    nonisolated public func key(for device: DeviceID) -> RestorationDeviceKey {
        store.key(for: device)
    }

    /// Pending entries for `device`.
    public func pending(for device: DeviceID) -> [RestorationEntry] {
        journal.pending(for: store.key(for: device))
    }

    /// Whether `setting` is already recorded for `device`.
    public func original(of setting: RestorableSetting, on device: DeviceID) -> RestorationValue? {
        pending(for: device).first { $0.setting == setting }?.original
    }

    /// Records an upcoming change and saves durably. On failure nothing is recorded.
    public func record(
        _ setting: RestorableSetting,
        on device: DeviceID,
        original: RestorationValue
    )
        throws(RestorationJournalStoreError)
    {
        var updated = journal
        updated.willApply(setting, on: store.key(for: device), original: original)
        try store.save(updated)
        journal = updated
    }

    /// Records a confirmed restore and saves. If saving fails the entry stays pending
    /// in memory too, so a later (idempotent) restore will run again.
    public func confirmRestored(_ setting: RestorableSetting, on device: DeviceID) throws(RestorationJournalStoreError)
    {
        var updated = journal
        updated.restored(setting, on: store.key(for: device))
        try store.save(updated)
        journal = updated
    }

    /// Records a failed restore attempt; the entry stays pending.
    public func recordFailure(_ setting: RestorableSetting, on device: DeviceID) throws(RestorationJournalStoreError) {
        var updated = journal
        updated.restoreFailed(setting, on: store.key(for: device))
        try store.save(updated)
        journal = updated
    }
}
