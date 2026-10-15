/// Everything known about who a device is and how it is reached.
///
/// Separates the three identity layers:
/// * ``id`` — logical identity used by the application,
/// * ``physical`` — firmware identity, when reported,
/// * ``endpoint`` — transport identity of the current link.
public struct DeviceIdentity: Hashable, Sendable, Codable {
    /// Logical identity.
    public let id: DeviceID
    /// Firmware identity, if the device has reported one.
    public let physical: PhysicalDeviceID?
    /// The most recent link to the device.
    public let endpoint: TransportEndpoint
    /// The reported model.
    public let model: DeviceModel
}

/// A sighting of a device on an endpoint, as reported by infrastructure.
public struct DeviceObservation: Hashable, Sendable {
    /// The link the device was seen on.
    public let endpoint: TransportEndpoint
    /// The reported model.
    public let model: DeviceModel
    /// The firmware identity, if it could be read.
    public let physical: PhysicalDeviceID?

    /// Creates an observation.
    public init(endpoint: TransportEndpoint, model: DeviceModel, physical: PhysicalDeviceID?) {
        self.endpoint = endpoint
        self.model = model
        self.physical = physical
    }
}
