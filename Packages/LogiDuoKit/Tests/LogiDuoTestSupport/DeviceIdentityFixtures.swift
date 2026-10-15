public import LogiDuoDomain

/// Builders for identity values with deterministic, obviously fake contents.
public enum IdentityFixtures {
    /// The Bluetooth product identifier of an MX Master 3S.
    public static let mxMaster3SBluetooth = ProductID(rawValue: 0xB034)
    /// A receiver-side product identifier for the same model.
    public static let mxMaster3SReceiver = ProductID(rawValue: 0x4082)

    /// A Bolt receiver with identity `name`.
    public static func boltReceiver(_ name: String = "bolt-A") -> ReceiverDescriptor {
        ReceiverDescriptor(
            id: unwrap(ReceiverID(rawValue: name)),
            hardware: HardwareIdentifier(vendor: .logitech, product: ProductID(rawValue: 0xC548))
        )
    }

    /// A receiver slot.
    public static func slot(_ number: UInt8) -> ReceiverSlot {
        unwrap(ReceiverSlot(rawValue: number))
    }

    /// A Bluetooth LE endpoint with key `key`.
    public static func bluetooth(_ key: String = "bt-1") -> TransportEndpoint {
        .direct(.bluetoothLowEnergy, unwrap(EndpointKey(rawValue: key)))
    }

    /// A mouse model named `name` with `product`.
    public static func mouse(_ name: String = "MX Master 3S", product: ProductID = mxMaster3SBluetooth) -> DeviceModel {
        unwrap(DeviceModel(name: name, product: product, category: .mouse))
    }

    /// A physical identity.
    public static func physical(model: UInt64 = 0xB034_4082_0000, unit: UInt32) -> PhysicalDeviceID {
        PhysicalDeviceID(model: unwrap(ModelID(rawValue: model)), unit: UnitID(rawValue: unit))
    }

    /// An observation.
    public static func observation(
        _ endpoint: TransportEndpoint,
        model: DeviceModel = mouse(),
        physical: PhysicalDeviceID? = nil
    ) -> DeviceObservation {
        DeviceObservation(endpoint: endpoint, model: model, physical: physical)
    }

    private static func unwrap<T>(_ value: T?) -> T {
        guard let value else { preconditionFailure("invalid fixture value") }
        return value
    }
}
