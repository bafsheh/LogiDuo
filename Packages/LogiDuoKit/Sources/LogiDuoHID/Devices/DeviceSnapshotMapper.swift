import LogiDuoDomain
import LogiDuoHIDPP

/// Translates HID++ readings into the domain's device description. Pure.
enum DeviceSnapshotMapper {
    /// The identity observation and draft snapshot for a freshly read device.
    static func describe(
        _ inventory: HIDPPDeviceInventory,
        endpoint: TransportEndpoint,
        fallbackName: String,
        product: ProductID
    ) -> (DeviceObservation, DeviceDraft) {
        let name = inventory.name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let category = category(typeCode: inventory.typeCode)
        let physical = inventory.information?.physicalID
        let model =
            DeviceModel(name: name, product: product, category: category)
            ?? DeviceModel(name: "Logitech device", product: product, category: category)
        let draft = DeviceDraft(
            name: name,
            category: category,
            transport: endpoint.transportType,
            link: .connected,
            battery: inventory.battery.map(battery),
            firmwareVersion: inventory.firmware.first { $0.type == 0 }?.description,
            model: physical?.model,
            features: features(inventory.features.map(\.feature))
        )
        // `DeviceModel` only fails for an empty name, which the fallback rules out.
        guard let model else { preconditionFailure("fallback device model is valid") }
        return (DeviceObservation(endpoint: endpoint, model: model, physical: physical), draft)
    }

    /// DeviceName type codes: 0 keyboard, 3 mouse, 4 trackpad, 5 trackball.
    static func category(typeCode: UInt8?) -> DeviceCategory {
        switch typeCode {
        case 0: .keyboard
        case 3, 4, 5: .mouse
        default: .unclassified
        }
    }

    /// A battery reading; charging codes differ between UnifiedBattery and BatteryStatus.
    static func battery(_ reading: BatteryReading) -> BatteryStatus {
        let charging: Set<UInt8> = reading.source == .unifiedBattery ? [1, 2] : [1, 2, 4]
        return BatteryStatus(percentage: reading.percentage, isCharging: charging.contains(reading.chargingStatusCode))
    }

    /// Feature flags from the feature table.
    static func features(_ table: [FeatureID]) -> DeviceFeatures {
        let known: [UInt16: DeviceFeatures] = [
            0x1B04: .reprogrammableControls,
            0x2201: .adjustableResolution,
            0x2202: .adjustableResolution,
            0x2110: .smartShift,
            0x2111: .smartShift,
            0x2121: .hiResWheel,
            0x2150: .thumbwheel,
            0x1000: .battery,
            0x1004: .battery,
            0x1981: .backlight,
            0x1982: .backlight,
            0x1983: .backlight,
            0x40A0: .fnInversion,
            0x40A2: .fnInversion,
            0x40A3: .fnInversion,
            0x19B0: .haptics,
        ]
        return table.reduce(into: DeviceFeatures()) { result, feature in
            if let flag = known[feature.rawValue] { result.insert(flag) }
        }
    }

    /// The person-facing link state for a connection state.
    static func link(for state: ConnectionState) -> DeviceLinkState {
        switch state {
        case .discovered, .connecting: .connecting
        case .connected: .connected
        case .recovering: .reconnecting
        case .suspended: .asleep
        case .disconnecting, .disconnected, .failed: .unavailable
        }
    }
}
