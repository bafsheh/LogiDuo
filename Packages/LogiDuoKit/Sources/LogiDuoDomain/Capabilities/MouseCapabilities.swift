/// The pointer resolution (DPI) range a mouse supports.
public struct ResolutionRange: Hashable, Sendable, Codable {
    /// The lowest supported resolution, in dots per inch.
    public let minimum: Int
    /// The highest supported resolution, in dots per inch.
    public let maximum: Int
    /// The spacing between supported values.
    public let step: Int

    /// Creates a range, rejecting non-positive values, an inverted range, or a
    /// maximum that is not reachable in whole steps from the minimum.
    public init?(minimum: Int, maximum: Int, step: Int) {
        guard minimum > 0, step > 0, maximum >= minimum, (maximum - minimum).isMultiple(of: step) else {
            return nil
        }
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
    }

    /// Whether `dpi` is exactly a supported value.
    public func contains(_ dpi: Int) -> Bool {
        (minimum...maximum).contains(dpi) && (dpi - minimum).isMultiple(of: step)
    }

    /// The supported value closest to `dpi`; ties round up.
    public func nearestSupported(to dpi: Int) -> Int {
        let clamped = min(max(dpi, minimum), maximum)
        let steps = ((clamped - minimum) * 2 + step) / (2 * step)
        return min(minimum + steps * step, maximum)
    }
}

/// SmartShift (automatic ratchet/free-spin switching) characteristics.
public struct SmartShiftCapability: Hashable, Sendable, Codable {
    /// Whether the wheel exposes adjustable ratchet torque (the enhanced variant).
    public let supportsTunableTorque: Bool

    /// Creates SmartShift characteristics.
    public init(supportsTunableTorque: Bool) {
        self.supportsTunableTorque = supportsTunableTorque
    }
}

/// Scroll wheel or thumbwheel characteristics.
public struct ScrollWheelCapability: Hashable, Sendable, Codable {
    /// Whether the device can invert its own scroll direction.
    public let supportsInversion: Bool

    /// Creates wheel characteristics.
    public init(supportsInversion: Bool) {
        self.supportsInversion = supportsInversion
    }
}

/// Gesture-button characteristics.
public struct GestureCapability: Hashable, Sendable, Codable {
    /// Buttons that can act as gesture buttons; never empty.
    public let buttons: Set<MouseButton>
    /// Whether movement while holding a gesture button is reported, enabling directional swipes.
    public let supportsDirectionalSwipes: Bool

    /// Creates gesture characteristics, rejecting an empty or protected button set.
    public init?(buttons: Set<MouseButton>, supportsDirectionalSwipes: Bool) {
        guard !buttons.isEmpty, !buttons.contains(where: \.isProtected) else { return nil }
        self.buttons = buttons
        self.supportsDirectionalSwipes = supportsDirectionalSwipes
    }
}

/// Battery reporting characteristics.
public struct BatteryReporting: Hashable, Sendable, Codable {
    /// Whether the device reports a percentage rather than only coarse levels.
    public let reportsPercentage: Bool

    /// Creates battery reporting characteristics.
    public init(reportsPercentage: Bool) {
        self.reportsPercentage = reportsPercentage
    }
}

/// Haptic feedback characteristics.
public struct HapticsCapability: Hashable, Sendable, Codable {
    /// Whether the device also has an adjustable force-sensing button.
    public let supportsForceSensing: Bool

    /// Creates haptics characteristics.
    public init(supportsForceSensing: Bool) {
        self.supportsForceSensing = supportsForceSensing
    }
}

/// Everything a mouse can do, as far as is known.
///
/// Built from a catalog expectation and refined by what the device reports at
/// runtime (see ``refined(by:)``); never derived from the model name alone.
public struct MouseCapabilities: Hashable, Sendable {
    /// Buttons the device can divert to LogiDuo over HID++.
    public var divertableButtons: CapabilityStatus<Set<MouseButton>>
    /// Adjustable pointer resolution.
    public var resolution: CapabilityStatus<ResolutionRange>
    /// SmartShift.
    public var smartShift: CapabilityStatus<SmartShiftCapability>
    /// High-resolution main wheel.
    public var highResolutionWheel: CapabilityStatus<ScrollWheelCapability>
    /// Horizontal thumbwheel.
    public var thumbwheel: CapabilityStatus<ScrollWheelCapability>
    /// Gesture buttons.
    public var gestures: CapabilityStatus<GestureCapability>
    /// Battery reporting.
    public var battery: CapabilityStatus<BatteryReporting>
    /// Haptic feedback.
    public var haptics: CapabilityStatus<HapticsCapability>

    /// Capabilities of a mouse that has not been queried yet.
    public static let undiscovered = MouseCapabilities()

    /// Creates a capability set; every capability defaults to undiscovered.
    public init(
        divertableButtons: CapabilityStatus<Set<MouseButton>> = .undiscovered,
        resolution: CapabilityStatus<ResolutionRange> = .undiscovered,
        smartShift: CapabilityStatus<SmartShiftCapability> = .undiscovered,
        highResolutionWheel: CapabilityStatus<ScrollWheelCapability> = .undiscovered,
        thumbwheel: CapabilityStatus<ScrollWheelCapability> = .undiscovered,
        gestures: CapabilityStatus<GestureCapability> = .undiscovered,
        battery: CapabilityStatus<BatteryReporting> = .undiscovered,
        haptics: CapabilityStatus<HapticsCapability> = .undiscovered
    ) {
        self.divertableButtons = divertableButtons
        self.resolution = resolution
        self.smartShift = smartShift
        self.highResolutionWheel = highResolutionWheel
        self.thumbwheel = thumbwheel
        self.gestures = gestures
        self.battery = battery
        self.haptics = haptics
    }

    /// Combines these (for example catalog) capabilities with newer (for example
    /// runtime) ones, field by field, using ``CapabilityStatus/refined(by:)``.
    public func refined(by newer: Self) -> Self {
        Self(
            divertableButtons: divertableButtons.refined(by: newer.divertableButtons),
            resolution: resolution.refined(by: newer.resolution),
            smartShift: smartShift.refined(by: newer.smartShift),
            highResolutionWheel: highResolutionWheel.refined(by: newer.highResolutionWheel),
            thumbwheel: thumbwheel.refined(by: newer.thumbwheel),
            gestures: gestures.refined(by: newer.gestures),
            battery: battery.refined(by: newer.battery),
            haptics: haptics.refined(by: newer.haptics)
        )
    }

    /// Whether LogiDuo can intercept presses of `button` on this device.
    ///
    /// Protected buttons are never available. System-reported buttons are
    /// always available. Other buttons require the device to divert them.
    public func remapAvailability(for button: MouseButton) -> Availability {
        if button.isProtected { return .unavailable }
        if button.isSystemReported { return .available }
        switch divertableButtons {
        case .undiscovered: return .pending
        case .unsupported: return .unavailable
        case .supported(let buttons): return buttons.contains(button) ? .available : .unavailable
        }
    }

    /// Inconsistencies between capabilities. An empty result means the set is coherent.
    public var issues: [CapabilityIssue] {
        var issues: [CapabilityIssue] = []
        let divertable = divertableButtons.detail ?? []
        for button in divertable.sorted(by: { $0.rawValue < $1.rawValue }) where button.isProtected {
            issues.append(.protectedButtonDivertable(button))
        }
        if let gestures = gestures.detail {
            if divertableButtons == .unsupported {
                issues.append(.gesturesWithoutDivertableButtons)
            }
            if divertableButtons.isSupported {
                let undivertable = gestures.buttons.filter { !$0.isSystemReported && !divertable.contains($0) }
                for button in undivertable.sorted(by: { $0.rawValue < $1.rawValue }) {
                    issues.append(.gestureButtonNotDivertable(button))
                }
            }
        }
        return issues
    }
}

/// A contradiction found in a capability set.
public enum CapabilityIssue: Hashable, Sendable {
    /// A protected button was reported as divertable; LogiDuo will still not remap it.
    case protectedButtonDivertable(MouseButton)
    /// Gestures were reported although no button can be diverted.
    case gesturesWithoutDivertableButtons
    /// A gesture button that is not system-reported is missing from the divertable buttons.
    case gestureButtonNotDivertable(MouseButton)
}
