/// Everything LogiDuo can learn about a device through read-only requests.
public struct HIDPPDeviceInventory: Hashable, Sendable {
    /// The HID++ protocol version.
    public let protocolVersion: HIDPPProtocolVersion
    /// The marketing name, if the device has DeviceNameType.
    public let name: String?
    /// The device type code, if available.
    public let typeCode: UInt8?
    /// The complete feature table, if the device has FeatureSet.
    public let features: [FeatureTableEntry]
    /// Unit and model identifiers, if the device has DeviceInformation.
    public let information: DeviceInformation?
    /// Firmware of every entity, if available.
    public let firmware: [FirmwareInfo]
    /// A battery reading, if the device reports one.
    public let battery: BatteryReading?

    /// Whether the feature table lists `feature`.
    public func supports(_ feature: FeatureID) -> Bool {
        features.contains { $0.feature == feature }
    }
}

/// Reads a ``HIDPPDeviceInventory`` using only read-only functions.
///
/// Absent features yield `nil` (or empty) fields. A device error for an
/// individual optional read is treated the same way; timeouts and transport
/// failures are thrown.
public struct DeviceInventoryReader<Device: HIDPPRequestPerforming>: Sendable {
    private let device: Device
    private let deviceIndex: DeviceIndex
    private let timeout: Duration?

    /// Reads the inventory of `deviceIndex`.
    public static func read(
        via device: Device,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> HIDPPDeviceInventory {
        try await DeviceInventoryReader(device: device, deviceIndex: deviceIndex, timeout: timeout).read()
    }

    private func read() async throws(HIDPPRequestError) -> HIDPPDeviceInventory {
        let version = try await RootFeature.protocolVersion(via: device, device: deviceIndex, timeout: timeout)
        let (name, typeCode) = try await nameAndType()
        let (information, firmware) = try await informationAndFirmware()
        return HIDPPDeviceInventory(
            protocolVersion: version,
            name: name,
            typeCode: typeCode,
            features: try await featureTable(),
            information: information,
            firmware: firmware,
            battery: try await battery()
        )
    }

    private func locate(_ feature: FeatureID) async throws(HIDPPRequestError) -> FeatureIndex? {
        let location = try await optional { () async throws(HIDPPRequestError) in
            try await RootFeature.location(of: feature, via: device, device: deviceIndex, timeout: timeout)
        }
        return location.flatMap { $0?.index }
    }

    private func featureTable() async throws(HIDPPRequestError) -> [FeatureTableEntry] {
        guard let index = try await locate(.featureSet) else { return [] }
        return try await optional { () async throws(HIDPPRequestError) in
            try await FeatureSetFeature.table(via: device, index: index, deviceIndex: deviceIndex, timeout: timeout)
        } ?? []
    }

    private func nameAndType() async throws(HIDPPRequestError) -> (String?, UInt8?) {
        guard let index = try await locate(.deviceName) else { return (nil, nil) }
        let name = try await optional { () async throws(HIDPPRequestError) in
            try await DeviceNameFeature.name(via: device, index: index, deviceIndex: deviceIndex, timeout: timeout)
        }
        let type = try await optional { () async throws(HIDPPRequestError) in
            try await DeviceNameFeature.typeCode(via: device, index: index, deviceIndex: deviceIndex, timeout: timeout)
        }
        return (name, type)
    }

    private func informationAndFirmware() async throws(HIDPPRequestError) -> (DeviceInformation?, [FirmwareInfo]) {
        guard let index = try await locate(.deviceInformation) else { return (nil, []) }
        let information = try await optional { () async throws(HIDPPRequestError) in
            try await DeviceInformationFeature.information(
                via: device,
                index: index,
                deviceIndex: deviceIndex,
                timeout: timeout
            )
        }
        var firmware: [FirmwareInfo] = []
        for entity in 0..<(information?.entityCount ?? 0) {
            let info = try await optional { () async throws(HIDPPRequestError) in
                try await DeviceInformationFeature.firmware(
                    entity: entity,
                    via: device,
                    index: index,
                    deviceIndex: deviceIndex,
                    timeout: timeout
                )
            }
            if let info { firmware.append(info) }
        }
        return (information, firmware)
    }

    private func battery() async throws(HIDPPRequestError) -> BatteryReading? {
        for feature in [FeatureID.unifiedBattery, .batteryStatus] {
            guard let index = try await locate(feature) else { continue }
            let reading = try await optional { () async throws(HIDPPRequestError) in
                try await BatteryFeature.reading(
                    feature: feature,
                    via: device,
                    index: index,
                    deviceIndex: deviceIndex,
                    timeout: timeout
                )
            }
            if let reading { return reading }
        }
        return nil
    }

    /// Runs `read`, mapping device-reported errors (feature or function absent) to `nil`.
    private func optional<T>(
        _ read: () async throws(HIDPPRequestError) -> T
    ) async throws(HIDPPRequestError) -> T? {
        do {
            return try await read()
        } catch {
            switch error {
            case .deviceError, .receiverError: return nil
            default: throw error
            }
        }
    }
}
