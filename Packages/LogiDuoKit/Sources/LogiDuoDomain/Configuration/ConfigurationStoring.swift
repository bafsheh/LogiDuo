public import Foundation

/// What loading the configuration found.
public enum ConfigurationLoadStatus: Hashable, Sendable {
    /// No configuration existed; defaults are in use.
    case fresh
    /// The stored configuration was loaded.
    case loaded
    /// The file was unreadable; it was kept aside at the URL and defaults are in use.
    case recovered(quarantinedAt: URL)
    /// Written by a newer LogiDuo: loaded as far as understood and never overwritten.
    case newerVersion(Int)
    /// Unreadable and could not be moved aside: left untouched, defaults in use, nothing saved.
    case unreadable

    /// Whether saving is allowed.
    public var isWritable: Bool {
        switch self {
        case .newerVersion, .unreadable: false
        case .fresh, .loaded, .recovered: true
        }
    }
}

/// Why the configuration could not be saved.
public enum ConfigurationStoreError: Error, Hashable, Sendable {
    /// The file was written by a newer LogiDuo and must not be overwritten.
    case readOnly
    /// The file system refused the operation.
    case fileSystem(String)
}

/// Durable storage for ``LogiDuoConfiguration``.
public protocol ConfigurationStoring: Sendable {
    /// Loads the configuration. Never fails: problems fall back to defaults and are reported.
    func load() -> (configuration: LogiDuoConfiguration, status: ConfigurationLoadStatus)
    /// Saves atomically and durably.
    func save(_ configuration: LogiDuoConfiguration) throws(ConfigurationStoreError)
}

/// Why changes are not being saved (or were reset), shown to the person.
public enum ConfigurationSaveProblem: Hashable, Sendable {
    /// The settings file is from a newer LogiDuo; changes last only until quit.
    case newerVersion
    /// The settings file could not be read or moved aside; changes last only until quit.
    case unreadable
    /// The settings file was unreadable, kept aside, and defaults are in use.
    case recoveredFromCorruption
    /// The last save failed.
    case saveFailed
}

/// The single owner of the in-memory configuration.
public protocol ConfigurationRepositing: Sendable {
    /// Why changes are not being saved, if they are not.
    func saveProblem() async -> ConfigurationSaveProblem?
    /// The current configuration.
    func current() async -> LogiDuoConfiguration
    /// Applies `change` and schedules a save.
    func update(_ change: @Sendable (inout LogiDuoConfiguration) -> Void) async
    /// Every configuration after a change, starting with the current one.
    func updates() async -> AsyncStream<LogiDuoConfiguration>
}
