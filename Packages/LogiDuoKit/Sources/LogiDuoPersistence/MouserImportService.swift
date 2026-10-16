public import Foundation
public import LogiDuoDomain

/// Previews and applies Mouser imports with rollback protection.
///
/// * Mouser's file is only read.
/// * Before applying, the current LogiDuo settings are written to a separate backup file;
///   if that fails nothing is changed. ``undoImport()`` restores the backup.
public actor MouserImportService<SaveClock: Clock>: MouserImportServicing where SaveClock.Duration == Duration {
    /// The mice an import's pointer settings apply to.
    public typealias Mice = @Sendable () async -> [DeviceID]

    private let repository: ConfigurationRepository<SaveClock>
    private let backup: FileConfigurationStore
    private let sourceURL: URL
    private let mice: Mice
    private let resolveApplication: MouserImporter.ApplicationResolver

    /// Creates a service.
    public init(
        repository: ConfigurationRepository<SaveClock>,
        backup: FileConfigurationStore,
        sourceURL: URL = MouserImporter.defaultFileURL(),
        mice: @escaping Mice,
        resolveApplication: @escaping MouserImporter.ApplicationResolver = MouserImporter.basicResolver
    ) {
        self.repository = repository
        self.backup = backup
        self.sourceURL = sourceURL
        self.mice = mice
        self.resolveApplication = resolveApplication
    }

    /// The backup location beside the configuration.
    public static func defaultBackupURL() -> URL {
        AtomicFile.supportDirectory().appendingPathComponent("configuration.before-mouser-import.json")
    }

    public func previewDefaultFile() -> Result<MouserImportPreview, MouserImportFailure> {
        preview(fileAt: sourceURL)
    }

    public func preview(fileAt url: URL) -> Result<MouserImportPreview, MouserImportFailure> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.fileNotFound) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        do {
            return .success(try MouserImporter.preview(data, resolveApplication: resolveApplication))
        } catch {
            return .failure(.invalid(error))
        }
    }

    public func apply(_ preview: MouserImportPreview) async -> Result<Void, MouserImportFailure> {
        let current = await repository.current()
        do {
            try backup.save(current)
        } catch {
            return .failure(.backupFailed)
        }
        let mice = await mice()
        await repository.update { $0 = preview.applied(to: $0, mice: mice) }
        await repository.flush()
        return .success(())
    }

    public func canUndoImport() -> Bool {
        FileManager.default.fileExists(atPath: backup.fileURL.path)
    }

    public func undoImport() async -> Bool {
        let restored = backup.load()
        guard restored.status == .loaded else { return false }
        let previous = restored.configuration
        await repository.update { $0 = previous }
        await repository.flush()
        try? FileManager.default.removeItem(at: backup.fileURL)
        return true
    }
}
