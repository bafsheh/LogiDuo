/// A USB-IF / Bluetooth SIG vendor identifier.
public struct VendorID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// Logitech's vendor identifier, shared by every Logitech HID interface.
    public static let logitech = VendorID(rawValue: 0x046D)

    /// The 16-bit vendor identifier.
    public let rawValue: UInt16

    /// Creates a vendor identifier.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Hexadecimal form, for example `0x046D`.
    public var description: String { "0x" + hexString(rawValue, digits: 4) }
}

/// A vendor-assigned product identifier.
///
/// The value describes the HID interface the host sees, not the physical device:
/// the same mouse reports one product identifier over Bluetooth and another
/// (the receiver's) through a USB receiver. Never use it alone as a device identity.
public struct ProductID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The 16-bit product identifier.
    public let rawValue: UInt16

    /// Creates a product identifier.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Hexadecimal form, for example `0xB034`.
    public var description: String { "0x" + hexString(rawValue, digits: 4) }
}

/// The vendor/product pair of a HID interface.
public struct HardwareIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The interface's vendor.
    public let vendor: VendorID
    /// The interface's product.
    public let product: ProductID

    /// Creates a vendor/product pair.
    public init(vendor: VendorID, product: ProductID) {
        self.vendor = vendor
        self.product = product
    }

    /// Whether the interface belongs to Logitech.
    public var isLogitech: Bool { vendor == .logitech }

    /// `vendor:product` in hexadecimal, for example `0x046D:0xB034`.
    public var description: String { "\(vendor):\(product)" }
}
