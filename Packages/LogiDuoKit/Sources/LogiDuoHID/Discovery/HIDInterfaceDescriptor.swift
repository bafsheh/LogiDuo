public import LogiDuoDomain
public import LogiDuoHIDPP

/// A usage page / usage pair declared by a HID interface.
public struct HIDUsage: Hashable, Sendable, CustomStringConvertible {
    /// Logitech's HID++ vendor page on USB receivers and wired devices.
    static let vendorPage: UInt32 = 0xFF00
    /// Logitech's HID++ vendor page on Bluetooth devices.
    static let bluetoothVendorPage: UInt32 = 0xFF43

    /// The usage page.
    public let page: UInt32
    /// The usage.
    public let usage: UInt32

    /// Creates a usage pair.
    public init(page: UInt32, usage: UInt32) {
        self.page = page
        self.usage = usage
    }

    /// `0xPAGE:0xUSAGE`.
    public var description: String {
        "0x" + String(page, radix: 16, uppercase: true) + ":0x" + String(usage, radix: 16, uppercase: true)
    }
}

/// What the system reports about one HID interface, read without opening it.
///
/// Values are copied from IOKit properties; the descriptor holds no IOKit objects.
public struct HIDInterfaceDescriptor: Hashable, Sendable {
    /// The IORegistry entry identifier of the HID service. Changes on reconnect.
    public let registryID: UInt64
    /// Vendor and product of the interface.
    public let hardware: HardwareIdentifier
    /// The product string, if any.
    public let productName: String?
    /// The transport string IOKit reports, for example `Bluetooth Low Energy` or `USB`.
    public let transport: String?
    /// Every top-level collection the interface declares.
    public let usages: [HIDUsage]
    /// The largest input report, in bytes.
    public let maximumInputReportSize: Int
    /// The largest output report, in bytes.
    public let maximumOutputReportSize: Int
    /// A stable, already-hashed key for the physical link (see ``EndpointKey``). Never a raw serial number.
    public let linkFingerprint: String?

    /// Creates a descriptor.
    public init(
        registryID: UInt64,
        hardware: HardwareIdentifier,
        productName: String?,
        transport: String?,
        usages: [HIDUsage],
        maximumInputReportSize: Int,
        maximumOutputReportSize: Int,
        linkFingerprint: String?
    ) {
        self.registryID = registryID
        self.hardware = hardware
        self.productName = productName
        self.transport = transport
        self.usages = usages
        self.maximumInputReportSize = maximumInputReportSize
        self.maximumOutputReportSize = maximumOutputReportSize
        self.linkFingerprint = linkFingerprint
    }
}

/// How LogiDuo may use a HID interface.
public enum HIDInterfaceRole: Hashable, Sendable {
    /// A device reached directly over `link`, with a HID++ long-report collection.
    case directDevice(DirectLink, HIDPPFraming)
    /// A wireless receiver whose paired devices are reached by slot.
    case receiver(ReceiverKind, HIDPPFraming)
    /// A Logitech interface without a HID++ collection (for example plain keyboard or mouse input).
    /// Never written to.
    case logitechWithoutHIDPP
    /// Not a Logitech interface.
    case unrelated

    /// Whether HID++ requests may be sent to this interface.
    public var acceptsHIDPP: Bool {
        switch self {
        case .directDevice, .receiver: true
        case .logitechWithoutHIDPP, .unrelated: false
        }
    }
}

/// Decides how an interface may be used, from its descriptor alone.
///
/// Rules:
/// * Non-Logitech interfaces are unrelated.
/// * A Logitech interface is a HID++ endpoint only if it declares a HID++
///   long-report collection — `0xFF00:0x0002` (USB) or `0xFF43:0x0202`
///   (Bluetooth) — and its output reports can hold a long report.
/// * Known receiver product identifiers are receivers; anything else is a
///   directly connected device whose link comes from the transport string.
/// * Short output reports are used only where a short collection
///   (`0xFF00:0x0001`) is declared; Bluetooth LE devices accept long reports only.
public enum HIDInterfaceClassifier {
    private static let longCollections: Set<HIDUsage> = [
        HIDUsage(page: HIDUsage.vendorPage, usage: 0x0002),
        HIDUsage(page: HIDUsage.bluetoothVendorPage, usage: 0x0202),
    ]
    private static let shortCollection = HIDUsage(page: HIDUsage.vendorPage, usage: 0x0001)

    /// Classifies `descriptor`.
    public static func role(of descriptor: HIDInterfaceDescriptor) -> HIDInterfaceRole {
        guard descriptor.hardware.isLogitech else { return .unrelated }
        let usages = Set(descriptor.usages)
        let fitsLong =
            descriptor.maximumOutputReportSize == 0
            || descriptor.maximumOutputReportSize >= HIDPPReportType.long.length
        guard !usages.isDisjoint(with: longCollections), fitsLong else { return .logitechWithoutHIDPP }

        let link = directLink(for: descriptor.transport)
        var outputs: Set<HIDPPReportType> = [.long]
        if usages.contains(shortCollection), link != .bluetoothLowEnergy {
            outputs.insert(.short)
        }
        let framing = HIDPPFraming(outputTypes: outputs, inputIncludesReportID: true)
        let receiverKind = ReceiverKind(product: descriptor.hardware.product)
        if receiverKind != .unknown {
            return .receiver(receiverKind, framing)
        }
        return .directDevice(link, framing)
    }

    /// Maps IOKit's transport string to a link type; unknown strings are treated as USB.
    static func directLink(for transport: String?) -> DirectLink {
        switch transport?.lowercased() {
        case "bluetooth low energy": .bluetoothLowEnergy
        case "bluetooth": .bluetoothClassic
        default: .usbWired
        }
    }
}

/// Hashes identifying strings (such as Bluetooth addresses) so that only a
/// fingerprint, never the raw value, is kept.
///
/// 64-bit FNV-1a: deterministic across launches; not a security primitive.
enum LinkFingerprint {
    static func make(_ parts: [String]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
