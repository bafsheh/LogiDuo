/// Where a known device's connection stands, as shown to the person.
public enum DeviceLinkState: Hashable, Sendable {
    /// Opening the connection or reading the device.
    case connecting
    /// Connected and answering.
    case connected
    /// Lost and trying again.
    case reconnecting
    /// Suspended while the Mac sleeps.
    case asleep
    /// Not reachable (switched off, out of range, or removed).
    case unavailable
}

/// A battery reading.
public struct BatteryStatus: Hashable, Sendable {
    /// Charge in percent, if the device reports one.
    public let percentage: Int?
    /// Whether the device is charging.
    public let isCharging: Bool

    /// Creates a reading.
    public init(percentage: Int?, isCharging: Bool) {
        self.percentage = percentage.map { min(100, max(0, $0)) }
        self.isCharging = isCharging
    }
}

/// Configurable features a device reported (read-only discovery).
public struct DeviceFeatures: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Reprogrammable controls (button diversion).
    public static let reprogrammableControls = DeviceFeatures(rawValue: 1 << 0)
    /// Adjustable pointer resolution.
    public static let adjustableResolution = DeviceFeatures(rawValue: 1 << 1)
    /// SmartShift wheel mode.
    public static let smartShift = DeviceFeatures(rawValue: 1 << 2)
    /// High-resolution wheel.
    public static let hiResWheel = DeviceFeatures(rawValue: 1 << 3)
    /// Thumbwheel.
    public static let thumbwheel = DeviceFeatures(rawValue: 1 << 4)
    /// Battery reporting.
    public static let battery = DeviceFeatures(rawValue: 1 << 5)
    /// Keyboard backlight.
    public static let backlight = DeviceFeatures(rawValue: 1 << 6)
    /// Function-key inversion.
    public static let fnInversion = DeviceFeatures(rawValue: 1 << 7)
    /// Haptic feedback.
    public static let haptics = DeviceFeatures(rawValue: 1 << 8)
}

/// The current pointer resolution and what the device allows.
public struct ResolutionState: Hashable, Sendable {
    /// The current resolution in DPI.
    public let current: Int
    /// The supported range.
    public let range: ResolutionRange

    /// Creates a state.
    public init(current: Int, range: ResolutionRange) {
        self.current = current
        self.range = range
    }
}

/// Everything the app shows about one device.
public struct DeviceSnapshot: Hashable, Sendable, Identifiable {
    /// The stable identity.
    public let id: DeviceID
    /// The reported (or catalogued) name.
    public var name: String
    /// Mouse, keyboard, ….
    public var category: DeviceCategory
    /// How it is attached.
    public var transport: TransportType
    /// The connection state.
    public var link: DeviceLinkState
    /// The latest battery reading.
    public var battery: BatteryStatus?
    /// The firmware version of the main entity, for example "RBM 22.02.B0009".
    public var firmwareVersion: String?
    /// The model identity, if the firmware reports one.
    public var model: ModelID?
    /// Configurable features.
    public var features: DeviceFeatures
    /// The pointer resolution, if readable.
    public var resolution: ResolutionState?
    /// The wheel mode, if readable.
    public var smartShift: SmartShiftMode?

    /// Creates a snapshot.
    public init(
        id: DeviceID,
        name: String,
        category: DeviceCategory,
        transport: TransportType,
        link: DeviceLinkState,
        battery: BatteryStatus? = nil,
        firmwareVersion: String? = nil,
        model: ModelID? = nil,
        features: DeviceFeatures = [],
        resolution: ResolutionState? = nil,
        smartShift: SmartShiftMode? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.transport = transport
        self.link = link
        self.battery = battery
        self.firmwareVersion = firmwareVersion
        self.model = model
        self.features = features
        self.resolution = resolution
        self.smartShift = smartShift
    }
}

/// The devices LogiDuo knows about in this session.
public protocol DeviceServicing: Sendable {
    /// The current devices, then every change.
    func snapshots() async -> AsyncStream<[DeviceSnapshot]>
    /// Re-reads every connected device (battery, resolution, …) and re-probes receivers.
    func refresh() async
}
