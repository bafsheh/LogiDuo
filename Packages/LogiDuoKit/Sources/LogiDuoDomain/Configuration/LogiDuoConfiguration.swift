/// Scrolling preferences, applied by the event tap.
public struct ScrollSettings: Hashable, Sendable, Codable {
    /// Inverts vertical wheel scrolling of Logitech mice.
    public var invertVertical: Bool
    /// Inverts horizontal (thumbwheel) scrolling of Logitech mice.
    public var invertHorizontal: Bool
    /// Leaves trackpads and other non-Logitech scroll sources untouched.
    public var ignoreTrackpad: Bool
    /// Turns vertical wheel scrolling into horizontal scrolling while Shift is held.
    public var shiftScrollsHorizontally: Bool
    /// Horizontal scroll distance (in lines) that fires one horizontal-scroll action.
    public var horizontalActionThreshold: Double

    /// Native behavior.
    public static let standard = ScrollSettings(
        invertVertical: false,
        invertHorizontal: false,
        ignoreTrackpad: true,
        shiftScrollsHorizontally: false,
        horizontalActionThreshold: 1
    )

    /// Creates settings.
    public init(
        invertVertical: Bool,
        invertHorizontal: Bool,
        ignoreTrackpad: Bool,
        shiftScrollsHorizontally: Bool,
        horizontalActionThreshold: Double
    ) {
        self.invertVertical = invertVertical
        self.invertHorizontal = invertHorizontal
        self.ignoreTrackpad = ignoreTrackpad
        self.shiftScrollsHorizontally = shiftScrollsHorizontally
        self.horizontalActionThreshold = min(20, max(0.1, horizontalActionThreshold))
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self.standard
        self.init(
            invertVertical: fields.lenient(Bool.self, .invertVertical) ?? base.invertVertical,
            invertHorizontal: fields.lenient(Bool.self, .invertHorizontal) ?? base.invertHorizontal,
            ignoreTrackpad: fields.lenient(Bool.self, .ignoreTrackpad) ?? base.ignoreTrackpad,
            shiftScrollsHorizontally: fields.lenient(Bool.self, .shiftScrollsHorizontally)
                ?? base.shiftScrollsHorizontally,
            horizontalActionThreshold: fields.lenient(Double.self, .horizontalActionThreshold)
                ?? base.horizontalActionThreshold
        )
    }
}

/// How the scroll wheel's ratchet behaves.
public enum SmartShiftMode: Hashable, Sendable, Codable {
    /// Always clicks (ratchet).
    case ratchet
    /// Always spins freely.
    case freeSpin
    /// Switches to free spin above `sensitivity` (1–50; higher needs a faster flick).
    case automatic(sensitivity: Int)
}

/// Per-device preferences, replayed whenever the device connects.
public struct DeviceSettings: Hashable, Sendable, Codable {
    /// The pointer resolution to apply, in DPI; `nil` leaves the device's own value.
    public var resolution: Int?
    /// Resolutions the "cycle resolution" action steps through, in order.
    public var resolutionPresets: [Int]
    /// The wheel mode to apply; `nil` leaves the device's own value.
    public var smartShift: SmartShiftMode?

    /// Nothing changed.
    public static let unchanged = DeviceSettings(
        resolution: nil,
        resolutionPresets: [800, 1600, 3200],
        smartShift: nil
    )

    /// Creates settings. Presets are de-duplicated and kept positive.
    public init(resolution: Int?, resolutionPresets: [Int], smartShift: SmartShiftMode?) {
        self.resolution = resolution.flatMap { $0 > 0 ? $0 : nil }
        var seen: Set<Int> = []
        self.resolutionPresets = resolutionPresets.filter { $0 > 0 && seen.insert($0).inserted }
        self.smartShift = smartShift
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            resolution: fields.lenient(Int.self, .resolution),
            resolutionPresets: fields.lenient([Int].self, .resolutionPresets) ?? Self.unchanged.resolutionPresets,
            smartShift: fields.lenient(SmartShiftMode.self, .smartShift)
        )
    }
}

/// Application-wide preferences.
public struct GeneralSettings: Hashable, Sendable, Codable {
    /// Whether remapping was on when the app last ran. Off on first launch.
    public var remappingEnabled: Bool
    /// Whether the main window opens at launch (otherwise only the menu bar item).
    public var showsWindowAtLaunch: Bool
    /// Gesture swipe distance in points.
    public var gestureThreshold: Double

    /// First-launch defaults.
    public static let standard = GeneralSettings(
        remappingEnabled: false,
        showsWindowAtLaunch: true,
        gestureThreshold: 25
    )

    /// Creates settings.
    public init(remappingEnabled: Bool, showsWindowAtLaunch: Bool, gestureThreshold: Double) {
        self.remappingEnabled = remappingEnabled
        self.showsWindowAtLaunch = showsWindowAtLaunch
        self.gestureThreshold = min(200, max(8, gestureThreshold))
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self.standard
        self.init(
            remappingEnabled: fields.lenient(Bool.self, .remappingEnabled) ?? base.remappingEnabled,
            showsWindowAtLaunch: fields.lenient(Bool.self, .showsWindowAtLaunch) ?? base.showsWindowAtLaunch,
            gestureThreshold: fields.lenient(Double.self, .gestureThreshold) ?? base.gestureThreshold
        )
    }
}

/// A stored application profile (validated into an ``ApplicationProfile`` on use).
public struct StoredProfile: Hashable, Sendable, Codable, Identifiable {
    /// The identity.
    public var id: ProfileID
    /// The display name.
    public var name: ProfileName
    /// Applications it applies to.
    public var matchers: [ApplicationMatcher]
    /// Mapping overrides.
    public var mappings: [ButtonMapping]
    /// Whether it can become active.
    public var isEnabled: Bool

    /// Creates a stored profile.
    public init(
        id: ProfileID,
        name: ProfileName,
        matchers: [ApplicationMatcher],
        mappings: [ButtonMapping] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.matchers = matchers
        self.mappings = mappings
        self.isEnabled = isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try fields.decode(ProfileID.self, forKey: .id),
            name: try fields.decode(ProfileName.self, forKey: .name),
            matchers: fields.lenientElements(ApplicationMatcher.self, .matchers),
            mappings: fields.lenientElements(ButtonMapping.self, .mappings),
            isEnabled: fields.lenient(Bool.self, .isEnabled) ?? true
        )
    }
}

/// Something in a loaded configuration that could not be used and was left out.
public enum ConfigurationIssue: Hashable, Sendable {
    /// The default mappings violated an invariant; the default profile was emptied.
    case invalidDefaultMappings(MappingRejection)
    /// A profile was invalid (no applications, or invalid mappings) and was left out.
    case invalidProfile(ProfileID)
    /// Two profiles shared an identifier; the later one was left out.
    case duplicateProfile(ProfileID)
}

/// Everything LogiDuo persists: mappings, profiles and preferences.
///
/// The active profile is runtime state and deliberately not stored. Decoding is
/// lenient field by field: an unreadable value falls back to its default, an
/// unreadable list element is dropped, so one bad entry never loses the rest.
public struct LogiDuoConfiguration: Hashable, Sendable, Codable {
    /// The schema version this build writes.
    public static let currentVersion = 1

    /// Mappings of the default profile.
    public var defaultMappings: [ButtonMapping]
    /// Application profiles, in priority order.
    public var profiles: [StoredProfile]
    /// Scroll preferences.
    public var scroll: ScrollSettings
    /// Application preferences.
    public var general: GeneralSettings
    /// Per-device preferences, keyed by device identifier.
    public var devices: [DeviceID: DeviceSettings]

    /// First-launch configuration: no mappings, native behavior.
    public static let standard = LogiDuoConfiguration(
        defaultMappings: [],
        profiles: [],
        scroll: .standard,
        general: .standard,
        devices: [:]
    )

    /// Creates a configuration.
    public init(
        defaultMappings: [ButtonMapping],
        profiles: [StoredProfile],
        scroll: ScrollSettings,
        general: GeneralSettings,
        devices: [DeviceID: DeviceSettings]
    ) {
        self.defaultMappings = defaultMappings
        self.profiles = profiles
        self.scroll = scroll
        self.general = general
        self.devices = devices
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self.standard
        self.init(
            defaultMappings: fields.lenientElements(ButtonMapping.self, .defaultMappings),
            profiles: fields.lenientElements(StoredProfile.self, .profiles),
            scroll: fields.lenient(ScrollSettings.self, .scroll) ?? base.scroll,
            general: fields.lenient(GeneralSettings.self, .general) ?? base.general,
            devices: fields.lenient([DeviceID: DeviceSettings].self, .devices) ?? [:]
        )
    }

    /// The settings of `device`, or the defaults.
    public func settings(for device: DeviceID) -> DeviceSettings {
        devices[device] ?? .unchanged
    }

    /// Validates mappings and profiles into a ``ProfileSet``, leaving out anything
    /// invalid and reporting it.
    public func profileSet() -> (profiles: ProfileSet, issues: [ConfigurationIssue]) {
        var issues: [ConfigurationIssue] = []
        let defaults: MappingSet
        do {
            defaults = try MappingSet(defaultMappings)
        } catch {
            issues.append(.invalidDefaultMappings(error))
            defaults = .empty
        }
        var seen: Set<ProfileID> = []
        var valid: [ApplicationProfile] = []
        for stored in profiles {
            guard seen.insert(stored.id).inserted else {
                issues.append(.duplicateProfile(stored.id))
                continue
            }
            guard
                let overrides = try? MappingSet(stored.mappings),
                let profile = ApplicationProfile(
                    id: stored.id,
                    name: stored.name,
                    matchers: stored.matchers,
                    overrides: overrides,
                    isEnabled: stored.isEnabled
                ),
                (try? ProfileSet(defaultMappings: defaults, applicationProfiles: [profile])) != nil
            else {
                issues.append(.invalidProfile(stored.id))
                continue
            }
            valid.append(profile)
        }
        let set = (try? ProfileSet(defaultMappings: defaults, applicationProfiles: valid)) ?? .empty
        return (set, issues)
    }
}

extension KeyedDecodingContainer {
    /// Decodes `key`, treating a missing or unreadable value as absent.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)).flatMap { $0 }
    }

    /// Decodes a list, dropping elements that cannot be read.
    func lenientElements<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard let elements = try? decodeIfPresent([Lenient<T>].self, forKey: key) else { return [] }
        return elements.compactMap(\.value)
    }
}

/// Decodes a value, or nothing if it is unreadable.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) {
        value = try? T(from: decoder)
    }
}
