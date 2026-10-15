/// An opaque identifier of a programmable keyboard key (a HID++ control identifier).
public struct KeyControlID: RawRepresentable, Hashable, Sendable, Codable {
    /// The 16-bit control identifier.
    public let rawValue: UInt16

    /// Creates a key control identifier.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

/// Everything a keyboard can do, as far as is known.
///
/// Keyboard support is not part of Mouser; these capabilities are placeholders
/// for researched features and are offered only once verified on hardware.
public struct KeyboardCapabilities: Hashable, Sendable {
    /// Keys the keyboard can divert to LogiDuo.
    public var programmableKeys: CapabilityStatus<Set<KeyControlID>>
    /// Whether the function-key row can be switched between media and F-keys.
    public var functionKeyInversion: CapabilityStatus<Presence>
    /// Adjustable backlight.
    public var backlight: CapabilityStatus<Presence>
    /// Battery reporting.
    public var battery: CapabilityStatus<BatteryReporting>

    /// Capabilities of a keyboard that has not been queried yet.
    public static let undiscovered = KeyboardCapabilities()

    /// Creates a capability set; every capability defaults to undiscovered.
    public init(
        programmableKeys: CapabilityStatus<Set<KeyControlID>> = .undiscovered,
        functionKeyInversion: CapabilityStatus<Presence> = .undiscovered,
        backlight: CapabilityStatus<Presence> = .undiscovered,
        battery: CapabilityStatus<BatteryReporting> = .undiscovered
    ) {
        self.programmableKeys = programmableKeys
        self.functionKeyInversion = functionKeyInversion
        self.backlight = backlight
        self.battery = battery
    }

    /// Combines these capabilities with newer ones, field by field.
    public func refined(by newer: Self) -> Self {
        Self(
            programmableKeys: programmableKeys.refined(by: newer.programmableKeys),
            functionKeyInversion: functionKeyInversion.refined(by: newer.functionKeyInversion),
            backlight: backlight.refined(by: newer.backlight),
            battery: battery.refined(by: newer.battery)
        )
    }
}

/// The capability model that applies to a device, chosen by its category.
public enum DeviceCapabilities: Hashable, Sendable {
    /// A mouse.
    case mouse(MouseCapabilities)
    /// A keyboard.
    case keyboard(KeyboardCapabilities)
    /// A receiver or unclassified device; no configurable features.
    case none

    /// Undiscovered capabilities for a device of `category`.
    public init(undiscoveredFor category: DeviceCategory) {
        switch category {
        case .mouse: self = .mouse(.undiscovered)
        case .keyboard: self = .keyboard(.undiscovered)
        case .receiver, .unclassified: self = .none
        }
    }

    /// Combines with newer capabilities of the same kind.
    ///
    /// - Throws: ``CapabilityKindMismatch`` if `newer` describes another kind of
    ///   device; callers must re-identify the device instead.
    public func refined(by newer: Self) throws(CapabilityKindMismatch) -> Self {
        switch (self, newer) {
        case (.mouse(let current), .mouse(let update)): .mouse(current.refined(by: update))
        case (.keyboard(let current), .keyboard(let update)): .keyboard(current.refined(by: update))
        case (.none, .none): .none
        default: throw CapabilityKindMismatch()
        }
    }
}

/// Raised when capabilities of one device kind are combined with another kind.
public struct CapabilityKindMismatch: Error, Hashable, Sendable {}
