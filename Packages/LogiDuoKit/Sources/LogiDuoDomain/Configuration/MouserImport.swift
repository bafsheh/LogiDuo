public import Foundation

/// Why a Mouser configuration cannot be imported at all.
public enum MouserImportError: Error, Hashable, Sendable {
    /// Not a JSON object.
    case notJSON
    /// Written by a Mouser newer than the schemas LogiDuo understands.
    case newerVersion(Int)
    /// The version field is not a whole number.
    case invalidVersion
    /// There are no profiles.
    case noProfiles
}

/// Something in the Mouser configuration that was not imported, or not as-is.
public enum MouserImportNote: Hashable, Sendable {
    /// An action LogiDuo does not have (for example a Windows-only action or the Actions Ring).
    case unsupportedAction(button: String, action: String)
    /// A button LogiDuo does not map (for example the Sense Panel).
    case unsupportedButton(String)
    /// A mapping that conflicted with the others (for example a click loop) and was left out.
    case conflictingMapping(button: String)
    /// An application that could not be identified on this Mac.
    case unknownApplication(profile: String, application: String)
    /// A profile without any identifiable application; left out.
    case skippedProfile(String)
    /// Mouser opened at login; LogiDuo's own setting is left unchanged.
    case startAtLoginNotImported
}

/// What a Mouser configuration becomes in LogiDuo, shown before anything is changed.
public struct MouserImportPreview: Hashable, Sendable {
    /// The schema version of the file.
    public let sourceVersion: Int
    /// The default mappings.
    public let defaultMappings: [ButtonMapping]
    /// Application profiles.
    public let profiles: [StoredProfile]
    /// Scroll preferences.
    public let scroll: ScrollSettings
    /// The gesture threshold.
    public let gestureThreshold: Double
    /// Pointer settings to give the connected mice (resolution, wheel mode).
    public let pointer: DeviceSettings
    /// Everything not imported as-is.
    public let notes: [MouserImportNote]

    /// The configuration after importing into `current`: mappings, profiles and scroll
    /// settings are replaced; everything else (devices, remapping state, window) is kept.
    public func applied(to current: LogiDuoConfiguration, mice: [DeviceID]) -> LogiDuoConfiguration {
        var result = current
        result.defaultMappings = defaultMappings
        result.profiles = profiles
        result.scroll = scroll
        result.general.gestureThreshold = gestureThreshold
        for mouse in mice {
            var settings = result.settings(for: mouse)
            settings.resolution = pointer.resolution ?? settings.resolution
            settings.smartShift = pointer.smartShift ?? settings.smartShift
            result.devices[mouse] = settings
        }
        return result
    }
}

/// Reads a Mouser `config.json` (schema versions 1–11) into a LogiDuo import preview. Pure:
/// the file is only read, never written.
public enum MouserImporter {
    /// The newest Mouser schema LogiDuo understands.
    public static let newestVersion = 11

    /// Mouser's configuration file on this Mac.
    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mouser/config.json")
    }

    /// Identifies an application from a Mouser profile entry (a bundle identifier, an
    /// application path or an executable name); `nil` if it cannot be identified.
    public typealias ApplicationResolver = @Sendable (String) -> ApplicationMatcher?

    /// Recognises bundle identifiers and absolute executable paths only.
    public static let basicResolver: ApplicationResolver = { entry in
        if entry.hasPrefix("/"), !entry.hasSuffix(".app") {
            return ExecutablePath(entry).map(ApplicationMatcher.executablePath)
        }
        if entry.contains("."), !entry.contains("/"), !entry.contains(" ") {
            return BundleIdentifier(entry).map(ApplicationMatcher.bundleIdentifier)
        }
        return nil
    }

    /// Builds a preview from the file's contents.
    public static func preview(
        _ data: Data,
        resolveApplication: ApplicationResolver = basicResolver
    ) throws(MouserImportError) -> MouserImportPreview {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw .notJSON }
        let version: Int
        switch root["version"] {
        case nil: version = 1
        case let number as Int: version = number
        default: throw .invalidVersion
        }
        guard version <= newestVersion else { throw .newerVersion(version) }
        guard let profiles = root["profiles"] as? [String: Any], !profiles.isEmpty else { throw .noProfiles }
        let settings = root["settings"] as? [String: Any] ?? [:]
        var notes: [MouserImportNote] = []

        var (defaults, stored) = translateProfiles(
            profiles,
            version: version,
            resolve: resolveApplication,
            notes: &notes
        )
        (defaults, stored) = MouserMappingTranslator.resolvingConflicts(
            defaults: defaults,
            profiles: stored,
            notes: &notes
        )
        if settings["start_at_login"] as? Bool == true { notes.append(.startAtLoginNotImported) }
        return MouserImportPreview(
            sourceVersion: version,
            defaultMappings: defaults,
            profiles: stored,
            scroll: scroll(settings, version: version),
            gestureThreshold: (settings["gesture_threshold"] as? Double) ?? GeneralSettings.standard.gestureThreshold,
            pointer: pointer(settings),
            notes: notes
        )
    }

    /// The default profile's mappings and the application profiles.
    private static func translateProfiles(
        _ profiles: [String: Any],
        version: Int,
        resolve: ApplicationResolver,
        notes: inout [MouserImportNote]
    ) -> ([ButtonMapping], [StoredProfile]) {
        var defaults: [ButtonMapping] = []
        var stored: [StoredProfile] = []
        for (key, value) in profiles.sorted(by: { $0.key < $1.key }) {
            let profile = value as? [String: Any] ?? [:]
            let raw = migrated(profile["mappings"] as? [String: Any] ?? [:], from: version)
            let mappings = MouserMappingTranslator.translate(raw, notes: &notes)
            if key == "default" {
                defaults = mappings
                continue
            }
            let label = (profile["label"] as? String) ?? key
            var matchers: [ApplicationMatcher] = []
            for entry in profile["apps"] as? [String] ?? [] {
                if let matcher = resolve(entry) {
                    matchers.append(matcher)
                } else {
                    notes.append(.unknownApplication(profile: label, application: entry))
                }
            }
            guard !matchers.isEmpty, let id = ProfileID(rawValue: "mouser." + key),
                let name = ProfileName(label) ?? ProfileName(key)
            else {
                notes.append(.skippedProfile(label))
                continue
            }
            stored.append(StoredProfile(id: id, name: name, matchers: matchers, mappings: mappings))
        }
        return (defaults, stored)
    }

    // MARK: - Migrations (only the steps that change what LogiDuo imports)

    /// Applies Mouser's migrations to one profile's mappings.
    static func migrated(_ mappings: [String: Any], from version: Int) -> [String: Any] {
        var result = mappings
        // v6 → v7: an unset mode shift became "toggle SmartShift".
        if version < 7, (result["mode_shift"] as? String ?? "none") == "none" {
            result["mode_shift"] = "toggle_smart_shift"
        }
        // v7 → v8: "toggle SmartShift" on mode shift became "switch scroll mode".
        if version < 8, result["mode_shift"] as? String == "toggle_smart_shift" {
            result["mode_shift"] = "switch_scroll_mode"
        }
        // Gesture Swipe unification: a gesture button doing nothing with swipes set means "swipes active".
        let swipes = ["gesture_left", "gesture_right", "gesture_up", "gesture_down"]
        if (result["gesture"] as? String ?? "none") == "none",
            swipes.contains(where: { (result[$0] as? String ?? "none") != "none" })
        {
            result["gesture"] = "gesture_swipe"
        }
        return result
    }

    private static func scroll(_ settings: [String: Any], version: Int) -> ScrollSettings {
        var threshold = (settings["hscroll_threshold"] as? Double) ?? 0.1
        // v9 → v10: the old integer default 1 became 0.1.
        if version < 10, threshold == 1 { threshold = 0.1 }
        return ScrollSettings(
            invertVertical: settings["invert_vscroll"] as? Bool ?? false,
            invertHorizontal: settings["invert_hscroll"] as? Bool ?? false,
            ignoreTrackpad: settings["ignore_trackpad"] as? Bool ?? true,
            shiftScrollsHorizontally: false,
            horizontalActionThreshold: threshold
        )
    }

    private static func pointer(_ settings: [String: Any]) -> DeviceSettings {
        let smartShift: SmartShiftMode? =
            if settings["smart_shift_enabled"] as? Bool == true {
                .automatic(sensitivity: min(50, max(1, settings["smart_shift_threshold"] as? Int ?? 25)))
            } else {
                switch settings["smart_shift_mode"] as? String {
                case "freespin": .freeSpin
                case "ratchet": .ratchet
                default: nil
                }
            }
        return DeviceSettings(
            resolution: settings["dpi"] as? Int,
            resolutionPresets: DeviceSettings.unchanged.resolutionPresets,
            smartShift: smartShift
        )
    }
}

/// Why an import could not be previewed or applied.
public enum MouserImportFailure: Error, Hashable, Sendable {
    /// No Mouser configuration at the expected place.
    case fileNotFound
    /// The file exists but could not be read.
    case unreadable
    /// The file's contents cannot be imported.
    case invalid(MouserImportError)
    /// The backup of the current settings could not be written, so nothing was changed.
    case backupFailed
}

/// Imports a Mouser configuration with a preview and a reversible apply.
public protocol MouserImportServicing: Sendable {
    /// Previews Mouser's configuration at its usual place (read-only).
    func previewDefaultFile() async -> Result<MouserImportPreview, MouserImportFailure>
    /// Previews the configuration in `url` (read-only).
    func preview(fileAt url: URL) async -> Result<MouserImportPreview, MouserImportFailure>
    /// Saves a backup of the current settings, then applies `preview`.
    func apply(_ preview: MouserImportPreview) async -> Result<Void, MouserImportFailure>
    /// Whether a backup from an import exists.
    func canUndoImport() async -> Bool
    /// Restores the settings from before the last import.
    func undoImport() async -> Bool
}
