import LogiDuoDomain
import LogiDuoHIDPP

/// Persistent setting writes, each confirmed by reading the setting back.
extension DeviceSession {
    /// Writes the resolution (snapped to the supported range) and reads it back.
    func setResolution(_ dpi: Int) async -> (DeviceSettingResult, Int?) {
        guard await connection.state == .connected else { return (.unavailable, nil) }
        guard let range = resolutionRange, let index = await index(of: .adjustableDPI) else {
            return (.unsupported, nil)
        }
        let target = range.nearestSupported(to: dpi)
        do {
            _ = try await AdjustableDPIFeature.set(target, via: connection, index: index, deviceIndex: deviceIndex)
            let confirmed = try await AdjustableDPIFeature.current(
                via: connection,
                index: index,
                deviceIndex: deviceIndex
            )
            return (confirmed == target ? .applied : .failed, confirmed)
        } catch {
            return (.failed, nil)
        }
    }

    /// Writes the SmartShift mode and reads it back.
    func setSmartShift(_ mode: SmartShiftMode) async -> (DeviceSettingResult, SmartShiftMode?) {
        guard await connection.state == .connected else { return (.unavailable, nil) }
        for feature in [FeatureID.smartShiftEnhanced, .smartShift] {
            guard let index = await index(of: feature) else { continue }
            do {
                try await SmartShiftFeature.set(
                    mode,
                    feature: feature,
                    via: connection,
                    index: index,
                    deviceIndex: deviceIndex
                )
                let confirmed = try await SmartShiftFeature.mode(
                    feature: feature,
                    via: connection,
                    index: index,
                    deviceIndex: deviceIndex
                )
                return (confirmed == mode ? .applied : .failed, confirmed)
            } catch {
                return (.failed, nil)
            }
        }
        return (.unsupported, nil)
    }

    /// Writes the function key mode for the current host and reads it back.
    func setFunctionKeys(_ mode: FunctionKeyMode) async -> (DeviceSettingResult, FunctionKeyMode?) {
        guard await connection.state == .connected else { return (.unavailable, nil) }
        guard let fn = await index(of: .fnInversionMultiHost) else { return (.unsupported, nil) }
        let host = await currentHost()
        do {
            try await KeyboardFeatures.setFunctionKeys(
                mode,
                host: host,
                via: connection,
                index: fn,
                deviceIndex: deviceIndex
            )
            let confirmed = try await KeyboardFeatures.functionKeys(
                host: host,
                via: connection,
                index: fn,
                deviceIndex: deviceIndex
            )
            return (confirmed == mode ? .applied : .failed, confirmed)
        } catch {
            return (.failed, nil)
        }
    }

    /// Writes the disabled keys and reads them back.
    func setDisabledKeys(_ keys: KeyboardKeys) async -> (DeviceSettingResult, KeyboardKeys?) {
        guard await connection.state == .connected else { return (.unavailable, nil) }
        guard let feature = await index(of: .disableKeys) else { return (.unsupported, nil) }
        do {
            try await KeyboardFeatures.setDisabledKeys(keys, via: connection, index: feature, deviceIndex: deviceIndex)
            let confirmed = try await KeyboardFeatures.disableKeys(
                via: connection,
                index: feature,
                deviceIndex: deviceIndex
            ).disabled
            return (confirmed == keys ? .applied : .failed, confirmed)
        } catch {
            return (.failed, nil)
        }
    }
}
