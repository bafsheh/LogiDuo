/// An opaque key for a direct (Bluetooth or USB) link to a device.
///
/// Infrastructure derives it from the host's view of the link (for example an
/// IOKit location); it is stable while the device stays paired but is not a
/// physical identity. Never shown or logged in full.
public struct EndpointKey: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The opaque key; never empty.
    public let rawValue: String

    /// Creates a key, rejecting empty or whitespace-only values.
    public init?(rawValue: String) {
        guard rawValue.contains(where: { !$0.isWhitespace }) else { return nil }
        self.rawValue = rawValue
    }

    /// A redacted form safe for logs.
    public var description: String { "EndpointKey(\(rawValue.count) chars)" }
}

/// Where a device is reachable right now: its transport identity.
///
/// Two devices can never share an endpoint at the same time, but one physical
/// device can move between endpoints (for example from a Bolt slot to
/// Bluetooth). Endpoint equality therefore identifies a *link*, not a device.
public enum TransportEndpoint: Hashable, Sendable, Codable {
    /// A device connected without a receiver.
    case direct(DirectLink, EndpointKey)
    /// A device paired to `receiver` in `slot`.
    case receiver(ReceiverDescriptor, ReceiverSlot)

    /// The transport family of this endpoint.
    public var transportType: TransportType {
        switch self {
        case .direct(.bluetoothLowEnergy, _): .bluetoothLowEnergy
        case .direct(.bluetoothClassic, _): .bluetoothClassic
        case .direct(.usbWired, _): .usbWired
        case .receiver(let receiver, _): .receiver(receiver.kind)
        }
    }

    /// The receiver hosting the device, if any.
    public var receiver: ReceiverDescriptor? {
        if case .receiver(let receiver, _) = self { receiver } else { nil }
    }

    /// A stable string unique to this endpoint, used to derive identities.
    var fingerprint: String {
        switch self {
        case .direct(let link, let key): "d.\(link.rawValue).\(key.rawValue)"
        case .receiver(let receiver, let slot): "r.\(receiver.id.rawValue).\(slot.rawValue)"
        }
    }
}
