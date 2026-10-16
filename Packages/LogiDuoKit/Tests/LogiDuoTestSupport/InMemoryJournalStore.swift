import Foundation
public import LogiDuoDomain

/// A journal store in memory, with failure injection.
public final class InMemoryJournalStore: RestorationJournalStoring, @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private var stored: RestorationJournal?
    private var failingSaves = 0
    private var corrupted = false
    public private(set) var saves = 0

    /// Creates an empty store.
    public init() {}

    /// The journal as last saved.
    public var persisted: RestorationJournal { lock.withLock { stored ?? RestorationJournal() } }

    /// Makes the next `count` saves fail.
    public func failNextSaves(_ count: Int) { lock.withLock { failingSaves = count } }

    /// Makes the next load report corruption.
    public func corrupt() { lock.withLock { corrupted = true } }

    /// Loads the journal.
    public func load() throws(RestorationJournalStoreError) -> RestorationJournal {
        lock.lock()
        defer { lock.unlock() }
        if corrupted {
            corrupted = false
            throw .corrupted(quarantinedAt: URL(fileURLWithPath: "/dev/null"))
        }
        return stored ?? RestorationJournal()
    }

    /// Saves the journal unless a failure was injected.
    public func save(_ journal: RestorationJournal) throws(RestorationJournalStoreError) {
        lock.lock()
        defer { lock.unlock() }
        if failingSaves > 0 {
            failingSaves -= 1
            throw .fileSystem("injected")
        }
        saves += 1
        stored = journal
    }

    /// An unsalted test key.
    public func key(for device: DeviceID) -> RestorationDeviceKey {
        RestorationDeviceKey(rawValue: "key:" + device.rawValue)
    }
}
