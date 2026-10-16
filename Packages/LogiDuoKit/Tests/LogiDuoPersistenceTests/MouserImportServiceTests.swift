import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoPersistence

@Suite("MouserImportService")
struct MouserImportServiceTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("logiduo-mouser-\(UUID().uuidString)", isDirectory: true)

    private static let mouser = #"""
        {"version": 9, "profiles": {"default": {"mappings": {"xbutton1": "alt_tab", "middle": "play_pause"}}},
         "settings": {"dpi": 1600, "invert_vscroll": true}}
        """#

    private func makeService(
        backupURL: URL? = nil
    ) throws -> (MouserImportService<ManualClock>, ConfigurationRepository<ManualClock>, URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("config.json")
        try Data(Self.mouser.utf8).write(to: source)
        var configuration = LogiDuoConfiguration.standard
        configuration.defaultMappings = [ButtonMapping(trigger: .press(.forward), action: .media(.mute))]
        let store = FileConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
        try store.save(configuration)
        let repository = ConfigurationRepository(store: store, clock: ManualClock())
        let service = MouserImportService(
            repository: repository,
            backup: FileConfigurationStore(fileURL: backupURL ?? directory.appendingPathComponent("backup.json")),
            sourceURL: source,
            mice: { [.fixture(1)] }
        )
        return (service, repository, source)
    }

    @Test("preview and apply never change Mouser's file; apply replaces mappings and settings")
    func applyLeavesSourceUntouched() async throws {
        let (service, repository, source) = try makeService()
        let before = try Data(contentsOf: source)
        let modified = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date

        let preview = try await service.previewDefaultFile().get()
        #expect(await repository.current().defaultMappings.count == 1, "previewing changes nothing")
        try await service.apply(preview).get()

        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == modified)
        let current = await repository.current()
        #expect(
            current.defaultMappings.contains(
                ButtonMapping(trigger: .press(.back), action: .shortcut(.switchApplications))
            )
        )
        #expect(current.scroll.invertVertical)
        #expect(current.settings(for: .fixture(1)).resolution == 1600)
        #expect(await service.canUndoImport())
    }

    @Test("undo restores the settings from before the import")
    func undo() async throws {
        let (service, repository, _) = try makeService()
        try await service.apply(try await service.previewDefaultFile().get()).get()

        #expect(await service.undoImport())

        #expect(
            await repository.current().defaultMappings == [
                ButtonMapping(trigger: .press(.forward), action: .media(.mute))
            ]
        )
        #expect(await !service.canUndoImport())
    }

    @Test("if the backup cannot be written, nothing is imported")
    func backupFailure() async throws {
        // A directory where the backup file should be makes the write fail.
        let blocked = directory.appendingPathComponent("blocked.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let (service, repository, _) = try makeService(backupURL: blocked)
        let preview = try await service.previewDefaultFile().get()

        guard case .failure(.backupFailed) = await service.apply(preview) else {
            Issue.record("expected the backup failure")
            return
        }
        #expect(
            await repository.current().defaultMappings == [
                ButtonMapping(trigger: .press(.forward), action: .media(.mute))
            ]
        )
    }

    @Test("a missing or invalid file is reported")
    func failures() async throws {
        let (service, _, source) = try makeService()
        #expect(
            await service.preview(fileAt: directory.appendingPathComponent("absent.json")) == .failure(.fileNotFound)
        )
        try Data(#"{"version": 30, "profiles": {"default": {}}}"#.utf8).write(to: source)
        #expect(await service.previewDefaultFile() == .failure(.invalid(.newerVersion(30))))
    }
}
