import Foundation
public import LogiDuoDomain

/// One entry of a device's feature table.
public struct FeatureTableEntry: Hashable, Sendable {
    /// The feature's position.
    public let index: FeatureIndex
    /// The feature's identifier.
    public let feature: FeatureID
    /// Type flags (bit 7 obsolete, bit 6 hidden, bit 5 engineering).
    public let typeFlags: UInt8
    /// Feature version.
    public let version: UInt8
}

/// Read-only access to FeatureSet (0x0001).
///
/// ```
/// fn0 getCount            → reply [count]   (features at indexes 1...count; Root is index 0)
/// fn1 getFeatureID(index) → reply [id_hi, id_lo, type, version]
/// ```
public enum FeatureSetFeature {
    /// Reads the whole feature table, Root included.
    public static func table(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> [FeatureTableEntry] {
        let count = try await device.perform(FeatureRequest.read(deviceIndex, index, 0), timeout: timeout).parameters[0]
        var entries = [FeatureTableEntry(index: .root, feature: .root, typeFlags: 0, version: 0)]
        for position in 1...max(count, 1) where count > 0 {
            let reply = try await device.perform(
                FeatureRequest.read(deviceIndex, index, 1, [position]),
                timeout: timeout
            )
            let parameters = reply.parameters
            entries.append(
                FeatureTableEntry(
                    index: FeatureIndex(rawValue: position),
                    feature: FeatureID(rawValue: FeatureRequest.bigEndian(parameters[0...1], as: UInt16.self)),
                    typeFlags: parameters[2],
                    version: parameters[3]
                )
            )
        }
        return entries
    }
}

/// Firmware identification for one entity (application, bootloader, hardware, …).
public struct FirmwareInfo: Hashable, Sendable, CustomStringConvertible {
    /// Entity type: 0 main application, 1 bootloader, 2 hardware, 3+ other.
    public let type: UInt8
    /// Three-character product prefix, for example `RBM`.
    public let prefix: String
    /// Firmware number (decoded from BCD).
    public let number: Int
    /// Revision (decoded from BCD).
    public let revision: Int
    /// Build (decoded from BCD).
    public let build: Int
    /// Whether this entity is the active firmware.
    public let isActive: Bool

    /// The vendor's display form, for example `RBM22.02_0009`.
    public var description: String {
        prefix + padded(number, 2) + "." + padded(revision, 2) + "_" + padded(build, 4)
    }

    private func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

/// What DeviceInformation (0x0003) reports about the unit.
public struct DeviceInformation: Hashable, Sendable {
    /// Number of firmware entities.
    public let entityCount: UInt8
    /// The firmware identity (unit and model) used for cross-transport reconciliation.
    public let physicalID: PhysicalDeviceID?
    /// Transport capability bits as reported.
    public let transportBits: UInt16
}

/// Read-only access to DeviceInformation (0x0003).
///
/// ```
/// fn0 getDeviceInfo        → [entities, unitID(4), transport(2), modelID(6), extModel, capabilities]
/// fn1 getFwInfo(entity)    → [type, prefix(3), number(BCD), revision(BCD), build(2, BCD), active, …]
/// ```
/// The serial-number function (fn2) is deliberately not exposed.
public enum DeviceInformationFeature {
    /// Reads unit and model identifiers.
    public static func information(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> DeviceInformation {
        let reply = try await device.perform(FeatureRequest.read(deviceIndex, index, 0), timeout: timeout).parameters
        let unit = UnitID(rawValue: FeatureRequest.bigEndian(reply[1...4], as: UInt32.self))
        let model = ModelID(rawValue: FeatureRequest.bigEndian(reply[7...12], as: UInt64.self))
        return DeviceInformation(
            entityCount: reply[0],
            physicalID: model.map { PhysicalDeviceID(model: $0, unit: unit) },
            transportBits: FeatureRequest.bigEndian(reply[5...6], as: UInt16.self)
        )
    }

    /// Reads firmware information for `entity`.
    public static func firmware(
        entity: UInt8,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> FirmwareInfo {
        let request = try FeatureRequest.read(deviceIndex, index, 1, [entity])
        let reply = try await device.perform(request, timeout: timeout).parameters
        let printable = reply[1...3].filter { (0x20...0x7E).contains($0) }
        return FirmwareInfo(
            type: reply[0] & 0x0F,
            prefix: String(bytes: printable, encoding: .ascii) ?? "",
            number: bcd(reply[4]),
            revision: bcd(reply[5]),
            build: bcd(reply[6]) * 100 + bcd(reply[7]),
            isActive: reply[8] & 0x01 != 0
        )
    }

    static func bcd(_ byte: UInt8) -> Int {
        Int(byte >> 4) * 10 + Int(byte & 0x0F)
    }
}

/// Read-only access to DeviceNameType (0x0005).
///
/// ```
/// fn0 getDeviceNameCount       → [length]
/// fn1 getDeviceName(offset)    → up to 16 name bytes
/// fn2 getDeviceType            → [type]
/// ```
public enum DeviceNameFeature {
    /// The marketing name, read in 16-byte chunks.
    public static func name(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> String {
        let length = Int(
            try await device.perform(FeatureRequest.read(deviceIndex, index, 0), timeout: timeout).parameters[0]
        )
        var bytes: [UInt8] = []
        while bytes.count < length {
            let request = try FeatureRequest.read(deviceIndex, index, 1, [UInt8(bytes.count)])
            let chunk = try await device.perform(request, timeout: timeout).parameters.prefix(length - bytes.count)
            guard !chunk.isEmpty else { break }
            bytes += chunk
        }
        let name = String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The device type code (0 keyboard, 3 mouse, 4 trackpad, 5 trackball, …).
    public static func typeCode(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> UInt8 {
        try await device.perform(FeatureRequest.read(deviceIndex, index, 2), timeout: timeout).parameters[0]
    }
}

/// A battery reading.
public struct BatteryReading: Hashable, Sendable {
    /// Charge in percent (0...100), or `nil` if the device reported an invalid value.
    public let percentage: Int?
    /// The raw charging-status code as reported (meaning differs between features).
    public let chargingStatusCode: UInt8
    /// The feature the reading came from.
    public let source: FeatureID
}

/// Read-only battery access (UnifiedBattery 0x1004 fn1 getStatus, BatteryStatus 0x1000 fn0).
///
/// ```
/// 0x1004 fn1 getStatus             → [percent, level flags, charging status, external power]
/// 0x1000 fn0 getBatteryLevelStatus → [percent, next level, status]
/// ```
public enum BatteryFeature {
    /// Reads the battery through whichever feature `feature` is.
    public static func reading(
        feature: FeatureID,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> BatteryReading {
        let function: UInt8 = feature == .unifiedBattery ? 1 : 0
        let reply = try await device.perform(FeatureRequest.read(deviceIndex, index, function), timeout: timeout)
            .parameters
        return BatteryReading(
            percentage: reply[0] <= 100 ? Int(reply[0]) : nil,
            chargingStatusCode: reply[2],
            source: feature
        )
    }
}
