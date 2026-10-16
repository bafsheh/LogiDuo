public import Foundation
public import LogiDuoDomain

/// Stores the configuration as one JSON file with a versioned envelope.
///
/// * Saves are atomic and durable (see `AtomicFile`); the previous file is kept as
///   `configuration.backup.json` before each replacement.
/// * An unreadable file is moved aside (never deleted) and defaults are used.
/// * A file from a newer schema version is read leniently and never overwritten.
public final class FileConfigurationStore: ConfigurationStoring, @unchecked Sendable {  // Invariant: `lock`.
    private struct Envelope: Codable {
        let version: Int
        let configuration: LogiDuoConfiguration
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// The configuration file.
    public let fileURL: URL
    private let lock = NSLock()
    private var readOnly = false

    /// The default location: `~/Library/Application Support/LogiDuo/configuration.json`.
    public static func defaultFileURL() -> URL {
        AtomicFile.supportDirectory().appendingPathComponent("configuration.json")
    }

    /// Creates a store for `fileURL`.
    public init(fileURL: URL = FileConfigurationStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// The backup of the previous configuration.
    public var backupURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("backup.json")
    }

    /// Loads the configuration; problems fall back to defaults and are reported.
    public func load() -> (configuration: LogiDuoConfiguration, status: ConfigurationLoadStatus) {
        lock.lock()
        defer { lock.unlock() }
        AtomicFile.removeStaleTemporaryFiles(of: fileURL)
        guard let data = try? Data(contentsOf: fileURL) else {
            readOnly = false
            return (.standard, .fresh)
        }
        let decoder = JSONDecoder()
        guard
            let probe = try? decoder.decode(VersionProbe.self, from: data),
            let envelope = try? decoder.decode(Envelope.self, from: data)
        else {
            return recoverFromUnreadableFile()
        }
        if probe.version > LogiDuoConfiguration.currentVersion {
            readOnly = true
            return (envelope.configuration, .newerVersion(probe.version))
        }
        readOnly = false
        return (envelope.configuration, .loaded)
    }

    /// Saves atomically and durably, keeping the previous file as a backup.
    public func save(_ configuration: LogiDuoConfiguration) throws(ConfigurationStoreError) {
        lock.lock()
        defer { lock.unlock() }
        guard !readOnly else { throw .readOnly }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                Envelope(version: LogiDuoConfiguration.currentVersion, configuration: configuration)
            )
        } catch {
            throw .fileSystem("encoding failed")
        }
        do {
            try AtomicFile.prepareDirectory(of: fileURL)
            if let previous = try? Data(contentsOf: fileURL), previous != data {
                try AtomicFile.write(previous, to: backupURL)
            }
            try AtomicFile.write(data, to: fileURL)
        } catch {
            throw .fileSystem("could not write the configuration")
        }
    }

    private func recoverFromUnreadableFile() -> (configuration: LogiDuoConfiguration, status: ConfigurationLoadStatus) {
        readOnly = false
        guard let destination = try? AtomicFile.quarantine(fileURL) else {
            // Could not move it aside: never overwrite what we could not read.
            readOnly = true
            return (.standard, .unreadable)
        }
        return (.standard, .recovered(quarantinedAt: destination))
    }
}
