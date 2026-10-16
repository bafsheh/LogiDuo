import Darwin
import Foundation

/// Why a file operation failed.
enum AtomicFileError: Error {
    case directory
    case write
    case replace
    case quarantine
}

/// Crash-safe file replacement shared by LogiDuo's stores.
///
/// A save writes a new file (mode 0600) beside the target, `fsync`s it, renames it
/// over the target (atomic on APFS/HFS+) and `fsync`s the directory, so a crash
/// leaves either the old or the new contents. A symlinked target is written through
/// to the file it points to, keeping the link.
enum AtomicFile {
    /// Creates the parent directory of `url` (mode 0700) if needed.
    static func prepareDirectory(of url: URL) throws(AtomicFileError) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .directory
        }
    }

    /// Replaces the contents of `url` with `data`, atomically and durably.
    static func write(_ data: Data, to url: URL) throws(AtomicFileError) {
        let target = resolvedTarget(of: url)
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw .write }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == data.count, synced else {
            unlink(temporary.path)
            throw .write
        }
        guard rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            throw .replace
        }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    /// Moves `url` aside (never deletes it) and returns where it went.
    static func quarantine(_ url: URL) throws(AtomicFileError) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw .quarantine
        }
        return destination
    }

    /// Removes temporary files a crash left beside `url`.
    static func removeStaleTemporaryFiles(of url: URL) {
        let target = resolvedTarget(of: url)
        let directory = target.deletingLastPathComponent()
        let prefix = ".\(target.lastPathComponent).tmp-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    /// The file a path finally refers to, following symbolic links — including links
    /// whose destination does not exist yet (`resolvingSymlinksInPath` leaves those alone).
    static func resolvedTarget(of url: URL) -> URL {
        var current = url
        for _ in 0..<8 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current =
                destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return current
    }

    /// The `~/Library/Application Support/LogiDuo` directory.
    static func supportDirectory() -> URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("LogiDuo", isDirectory: true)
    }
}
