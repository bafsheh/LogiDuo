import Foundation
import LogiDuoDomain
import LogiDuoPersistence
import LogiDuoTestSupport
import Testing

@Suite("FileRestorationJournalStore")
struct FileRestorationJournalStoreTests {
    private let directory: URL
    private let file: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logiduo-journal-\(UUID().uuidString)"
        )
        file = directory.appendingPathComponent("LogiDuo/restoration-journal.json")
    }

    private func sampleJournal(_ store: FileRestorationJournalStore) -> RestorationJournal {
        var journal = RestorationJournal()
        journal.willApply(
            .controlReporting(DeviceControlID(rawValue: 0x00C3)),
            on: store.key(for: .fixture(1)),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )
        return journal
    }

    @Test("an absent journal loads as empty")
    func absent() throws {
        #expect(try FileRestorationJournalStore(fileURL: file).load().isClean)
    }

    @Test("a saved journal survives a new store instance with the same device keys")
    func roundTrip() throws {
        let store = FileRestorationJournalStore(fileURL: file)
        let journal = sampleJournal(store)
        try store.save(journal)

        let reopened = FileRestorationJournalStore(fileURL: file)
        let loaded = try reopened.load()

        #expect(loaded == journal)
        #expect(reopened.key(for: .fixture(1)) == store.key(for: .fixture(1)))
        #expect(!loaded.pending(for: reopened.key(for: .fixture(1))).isEmpty)
    }

    @Test("the file is private and never contains the raw device identity")
    func privacy() throws {
        let store = FileRestorationJournalStore(fileURL: file)
        try store.save(sampleJournal(store))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: file.deletingLastPathComponent().path
        )
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? Int) == 0o700)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(!contents.contains(DeviceID.fixture(1).rawValue))
    }

    @Test("keys differ between installations (random salt)")
    func saltedKeys() throws {
        let other = directory.appendingPathComponent("Other/restoration-journal.json")
        let first = FileRestorationJournalStore(fileURL: file)
        let second = FileRestorationJournalStore(fileURL: other)
        try first.save(RestorationJournal())
        try second.save(RestorationJournal())
        #expect(first.key(for: .fixture(1)) != second.key(for: .fixture(1)))
    }

    @Test("a corrupted journal is moved aside, kept, and reported")
    func corruption() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let store = FileRestorationJournalStore(fileURL: file)

        let error = #expect(throws: RestorationJournalStoreError.self) { try store.load() }
        guard case .corrupted(let quarantined)? = error else {
            Issue.record("expected corruption")
            return
        }
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(try Data(contentsOf: quarantined) == Data("{not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("an interrupted write leaves the previous journal intact and the stale file is cleaned")
    func interruptedWrite() throws {
        let store = FileRestorationJournalStore(fileURL: file)
        let journal = sampleJournal(store)
        try store.save(journal)
        let stale = file.deletingLastPathComponent().appendingPathComponent(".restoration-journal.json.tmp-crashed")
        try Data("{\"partial\":".utf8).write(to: stale)

        let loaded = try FileRestorationJournalStore(fileURL: file).load()

        #expect(loaded == journal)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("a journal from a newer version is treated as unreadable, not misread")
    func futureVersion() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = #"{"version":99,"salt":"AAAAAAAAAAAAAAAAAAAAAA==","journal":{"records":[]}}"#
        try Data(future.utf8).write(to: file)
        #expect(throws: RestorationJournalStoreError.self) { try FileRestorationJournalStore(fileURL: file).load() }
    }

    @Test("saving an empty journal keeps the salt so keys stay stable")
    func emptySaveKeepsSalt() throws {
        let store = FileRestorationJournalStore(fileURL: file)
        let key = store.key(for: .fixture(3))
        try store.save(RestorationJournal())
        #expect(FileRestorationJournalStore(fileURL: file).key(for: .fixture(3)) == key)
    }
}
