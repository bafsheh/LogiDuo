import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoPersistence

@Suite("FileConfigurationStore and ConfigurationRepository")
struct FileConfigurationStoreTests {
    private let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("logiduo-config-tests-\(UUID().uuidString)", isDirectory: true)

    private var fileURL: URL { directory.appendingPathComponent("configuration.json") }

    private static var edited: LogiDuoConfiguration {
        var configuration = LogiDuoConfiguration.standard
        configuration.scroll.invertVertical = true
        configuration.defaultMappings = [ButtonMapping(trigger: .press(.back), action: .system(.missionControl))]
        return configuration
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    @Test("no file is a fresh start with defaults")
    func fresh() {
        let loaded = FileConfigurationStore(fileURL: fileURL).load()
        #expect(loaded.status == .fresh)
        #expect(loaded.configuration == .standard)
    }

    @Test("saves round-trip, with owner-only permissions")
    func roundTrip() throws {
        let store = FileConfigurationStore(fileURL: fileURL)
        try store.save(Self.edited)

        let reloaded = FileConfigurationStore(fileURL: fileURL).load()
        #expect(reloaded.status == .loaded)
        #expect(reloaded.configuration == Self.edited)
        let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("the previous file is kept as a backup")
    func backup() throws {
        let store = FileConfigurationStore(fileURL: fileURL)
        try store.save(.standard)
        try store.save(Self.edited)

        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: store.backupURL)) as? [String: Any]
        #expect(backup?["version"] as? Int == LogiDuoConfiguration.currentVersion)
        #expect(FileConfigurationStore(fileURL: store.backupURL).load().configuration == .standard)
    }

    @Test("an unreadable file is moved aside, never deleted, and defaults are used")
    func corrupted() throws {
        try write("{ not json")
        let loaded = FileConfigurationStore(fileURL: fileURL).load()

        guard case .recovered(let quarantined) = loaded.status else {
            Issue.record("expected recovery, got \(loaded.status)")
            return
        }
        #expect(loaded.configuration == .standard)
        #expect(try String(contentsOf: quarantined, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("a newer schema version is read leniently and never overwritten")
    func newerVersion() throws {
        let text = #"{"version": 99, "configuration": {"scroll": {"invertVertical": true}, "future": 1}}"#
        try write(text)
        let store = FileConfigurationStore(fileURL: fileURL)

        let loaded = store.load()

        #expect(loaded.status == .newerVersion(99))
        #expect(loaded.configuration.scroll.invertVertical)
        #expect(throws: ConfigurationStoreError.readOnly) { try store.save(.standard) }
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == text)
    }

    @Test("a symlinked configuration is written through, keeping the link")
    func symlink() throws {
        let real = directory.appendingPathComponent("real.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: real)

        try FileConfigurationStore(fileURL: fileURL).save(Self.edited)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path) == real.path)
        #expect(FileConfigurationStore(fileURL: real).load().configuration == Self.edited)
    }

    // MARK: Repository

    @Test("a burst of changes is broadcast at once and saved once after the delay")
    func debounced() async {
        let store = FileConfigurationStore(fileURL: fileURL)
        let clock = ManualClock()
        let repository = ConfigurationRepository(store: store, clock: clock, delay: .milliseconds(500))
        for _ in 0..<5 {
            await repository.update { $0.scroll.invertVertical.toggle() }
        }

        #expect(await repository.current().scroll.invertVertical)
        #expect(await repository.saveCount == 0)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { await repository.saveCount == 1 })
        #expect(store.load().configuration.scroll.invertVertical)
    }

    @Test("flush saves immediately; an unchanged update saves nothing")
    func flush() async {
        let store = FileConfigurationStore(fileURL: fileURL)
        let repository = ConfigurationRepository(store: store, clock: ManualClock())
        await repository.update { $0.general.showsWindowAtLaunch = true }
        #expect(await repository.saveCount == 0)
        await repository.update { $0.general.remappingEnabled = true }
        await repository.flush()
        #expect(await repository.saveCount == 1)
        #expect(store.load().configuration.general.remappingEnabled)
    }

    @Test("subscribers get the current value, then every change")
    func updates() async {
        let repository = ConfigurationRepository(store: FileConfigurationStore(fileURL: fileURL), clock: ManualClock())
        var iterator = await repository.updates().makeAsyncIterator()
        #expect(await iterator.next() == .standard)
        await repository.update { $0.scroll.invertHorizontal = true }
        #expect(await iterator.next()?.scroll.invertHorizontal == true)
    }

    @Test("a read-only configuration is never written, and the failure is visible")
    func readOnlyRepository() async throws {
        let text = #"{"version": 99, "configuration": {}}"#
        try write(text)
        let repository = ConfigurationRepository(store: FileConfigurationStore(fileURL: fileURL), clock: ManualClock())
        await repository.update { $0.scroll.invertVertical = true }
        await repository.flush()

        #expect(await repository.lastSaveError == .readOnly)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == text)
    }
}

@Suite("ConfigurationRepository save problems")
struct ConfigurationSaveProblemTests {
    @Test("a newer-version file is reported; a fresh store reports nothing")
    func problems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logiduo-problem-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("configuration.json")
        #expect(
            await ConfigurationRepository(store: FileConfigurationStore(fileURL: file), clock: ManualClock())
                .saveProblem() == nil
        )
        try Data(#"{"version": 99, "configuration": {}}"#.utf8).write(to: file)
        #expect(
            await ConfigurationRepository(store: FileConfigurationStore(fileURL: file), clock: ManualClock())
                .saveProblem() == .newerVersion
        )
    }
}
