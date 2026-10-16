import CryptoKit
import Darwin
public import Foundation
public import LogiDuoDomain

/// Stores the restoration journal in one JSON file, atomically and durably.
///
/// * **Atomic and durable.** Each save writes a new file (mode 0600) beside the
///   journal, `fsync`s it, renames it over the journal (atomic on APFS/HFS+) and
///   `fsync`s the directory; then reads it back and compares. A crash at any point
///   leaves either the previous or the new journal, never a partial one.
/// * **Corruption.** An unreadable journal is renamed aside (never deleted) and
///   reported, so recovery information is not silently lost.
/// * **Privacy.** Device keys are a salted SHA-256 of the device identity; the salt
///   is random per installation. The file never contains unit identifiers.
/// * The directory is created with mode 0700.
public final class FileRestorationJournalStore: RestorationJournalStoring, @unchecked Sendable {  // Invariant: `lock`.
    private struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        let salt: Data
        let journal: RestorationJournal
    }

    /// The journal file.
    public let fileURL: URL
    private let lock = NSLock()
    private var salt: Data?

    /// The default location: `~/Library/Application Support/LogiDuo/restoration-journal.json`.
    public static func defaultFileURL() -> URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("LogiDuo", isDirectory: true).appendingPathComponent(
            "restoration-journal.json"
        )
    }

    /// Creates a store for `fileURL`.
    public init(fileURL: URL = FileRestorationJournalStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Loads the journal; an absent file is an empty journal. Stale temporary files are removed.
    public func load() throws(RestorationJournalStoreError) -> RestorationJournal {
        lock.lock()
        defer { lock.unlock() }
        removeStaleTemporaryFiles()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return RestorationJournal() }
        let envelope = try readEnvelope()
        salt = envelope.salt
        return envelope.journal
    }

    /// Saves atomically and durably, then verifies by reading back.
    public func save(_ journal: RestorationJournal) throws(RestorationJournalStoreError) {
        lock.lock()
        defer { lock.unlock() }
        let envelope = Envelope(version: Envelope.currentVersion, salt: currentSalt(), journal: journal)
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw .fileSystem("encoding failed")
        }
        try prepareDirectory()
        try writeAtomically(data)
        guard (try? readEnvelope())?.journal == journal else { throw .notDurable }
    }

    /// A salted hash of the device identity.
    public func key(for device: DeviceID) -> RestorationDeviceKey {
        let salt = lock.withLock { currentSalt() }
        let digest = SHA256.hash(data: salt + Data(device.rawValue.utf8))
        return RestorationDeviceKey(rawValue: digest.prefix(16).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - File handling

    private func currentSalt() -> Data {
        if let salt { return salt }
        if let existing = try? readEnvelope().salt {
            salt = existing
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)  // Darwin's cryptographically secure generator.
        let generated = Data(bytes)
        salt = generated
        return generated
    }

    private func readEnvelope() throws(RestorationJournalStoreError) -> Envelope {
        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version <= Envelope.currentVersion else { throw CocoaError(.fileReadCorruptFile) }
            return envelope
        } catch {
            throw .corrupted(quarantinedAt: try quarantine())
        }
    }

    private func quarantine() throws(RestorationJournalStoreError) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
        } catch {
            throw .fileSystem("could not move the corrupted journal aside")
        }
        return destination
    }

    private func prepareDirectory() throws(RestorationJournalStoreError) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .fileSystem("could not create the journal directory")
        }
    }

    private func writeAtomically(_ data: Data) throws(RestorationJournalStoreError) {
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw .fileSystem("could not create a temporary journal file") }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == data.count, synced else {
            unlink(temporary.path)
            throw .fileSystem("could not write the journal durably")
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            unlink(temporary.path)
            throw .fileSystem("could not replace the journal")
        }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    private func removeStaleTemporaryFiles() {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = ".\(fileURL.lastPathComponent).tmp-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            unlink(directory.appendingPathComponent(name).path)
        }
    }
}
