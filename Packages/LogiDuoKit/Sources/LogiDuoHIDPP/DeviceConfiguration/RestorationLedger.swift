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
    private var quarantined: RestorationJournalStoreError?
    private var inherited: Set<RestorationDeviceKey> = []
    private var busy: Set<RestorationDeviceKey> = []
    private var waiters: [RestorationDeviceKey: [CheckedContinuation<Void, Never>]] = [:]

    /// Creates a ledger over `store`. Call ``load()`` before use.
    public init(store: any RestorationJournalStoring) {
        self.store = store
    }

    /// Waits until no other configuration operation runs on `device`, then claims it.
    ///
    /// Divert and restore of one device are serialized (first come, first served)
    /// so a restore can never interleave with a divert and orphan its effect.
    /// Every call must be balanced by ``endExclusive(_:)``.
    public func beginExclusive(_ device: DeviceID) async {
        let key = store.key(for: device)
        guard busy.contains(key) else {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    /// Releases the claim on `device`, handing it to the next waiter.
    public func endExclusive(_ device: DeviceID) {
        let key = store.key(for: device)
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(key)
        }
    }

    /// Loads the journal from disk.
    ///
    /// After a corrupted load, nothing new can be recorded (so nothing new can be
    /// diverted) until ``acknowledgeCorruption()``; the unreadable file stays in
    /// quarantine. Devices with entries from an earlier run must be restored
    /// before they can be configured again.
    public func load() -> LoadOutcome {
        do {
            journal = try store.load()
            quarantined = nil
            inherited = journal.devicesNeedingRestoration
            return journal.isClean ? .clean : .pending(entries: journal.entries.count)
        } catch {
            journal = RestorationJournal()
            quarantined = error
            inherited = []
            return .corrupted
        }
    }

    /// The load failure that blocks new records, if any.
    public var corruption: RestorationJournalStoreError? { quarantined }

    /// Records that the person has seen the corrupted-journal notice and resolved the
    /// device state (for example with an emergency reset). The quarantined file is kept.
    public func acknowledgeCorruption() {
        quarantined = nil
    }

    /// Whether `device` still has entries left by an earlier run.
    public func hasInheritedEntries(_ device: DeviceID) -> Bool {
        inherited.contains(store.key(for: device))
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
        if let quarantined { throw quarantined }
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
        if updated.pending(for: store.key(for: device)).isEmpty { inherited.remove(store.key(for: device)) }
    }

    /// Records a failed restore attempt; the entry stays pending.
    public func recordFailure(_ setting: RestorableSetting, on device: DeviceID) throws(RestorationJournalStoreError) {
        var updated = journal
        updated.restoreFailed(setting, on: store.key(for: device))
        try store.save(updated)
        journal = updated
    }
}
