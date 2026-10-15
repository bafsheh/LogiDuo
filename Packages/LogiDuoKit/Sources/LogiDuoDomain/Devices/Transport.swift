/// The family of a wireless USB receiver.
public enum ReceiverKind: String, CaseIterable, Hashable, Sendable, Codable {
    /// Logi Bolt receiver.
    case bolt
    /// Logitech Unifying receiver.
    case unifying
    /// A receiver LogiDuo has no verified knowledge of.
    case unknown

    /// The number of devices the receiver can pair (HID++ device indexes 1...6).
    public var pairingSlotCount: Int { 6 }

    /// Classifies a receiver from its USB product identifier.
    ///
    /// Only product identifiers with verified evidence are classified; every
    /// other value is `.unknown` rather than guessed.
    /// - Parameter product: The receiver's USB product identifier.
    public init(product: ProductID) {
        switch product.rawValue {
        case 0xC548: self = .bolt
        case 0xC52B: self = .unifying
        default: self = .unknown
        }
    }
}

/// How the host currently reaches a device.
public enum TransportType: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Directly over Bluetooth Low Energy.
    case bluetoothLowEnergy
    /// Directly over Bluetooth Classic.
    case bluetoothClassic
    /// Directly over a USB cable.
    case usbWired
    /// Through a paired wireless receiver.
    case receiver(ReceiverKind)

    /// A short, user-presentable name.
    public var description: String {
        switch self {
        case .bluetoothLowEnergy: "Bluetooth LE"
        case .bluetoothClassic: "Bluetooth"
        case .usbWired: "USB"
        case .receiver(let kind): "\(kind.rawValue) receiver"
        }
    }
}

/// A direct (receiver-less) link type.
public enum DirectLink: String, CaseIterable, Hashable, Sendable, Codable {
    /// Bluetooth Low Energy.
    case bluetoothLowEnergy
    /// Bluetooth Classic.
    case bluetoothClassic
    /// USB cable.
    case usbWired
}
