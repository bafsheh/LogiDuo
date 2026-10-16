public import LogiDuoDomain
import LogiDuoHIDPP

/// Persistent device settings. Every change is refused while writes are not authorized.
extension DeviceDirectory {
    /// Sets the pointer resolution of `device`.
    public func setResolution(_ dpi: Int, on device: DeviceID) async -> DeviceSettingResult {
        guard authorization == .enabled else { return .writesDisabled }
        guard let session = session(for: device) else { return .unavailable }
        let (result, confirmed) = await session.setResolution(dpi)
        if let confirmed, let range = snapshotsByID[device]?.resolution?.range {
            snapshotsByID[device]?.resolution = ResolutionState(current: confirmed, range: range)
            broadcast()
        }
        return result
    }

    /// Sets the SmartShift mode of `device`.
    public func setSmartShift(_ mode: SmartShiftMode, on device: DeviceID) async -> DeviceSettingResult {
        guard authorization == .enabled else { return .writesDisabled }
        guard let session = session(for: device) else { return .unavailable }
        let (result, confirmed) = await session.setSmartShift(mode)
        if let confirmed {
            snapshotsByID[device]?.smartShift = confirmed
            broadcast()
        }
        return result
    }

    /// Sets what F1, F2, … do on `device`.
    public func setFunctionKeys(_ mode: FunctionKeyMode, on device: DeviceID) async -> DeviceSettingResult {
        guard authorization == .enabled else { return .writesDisabled }
        guard let session = session(for: device) else { return .unavailable }
        let (result, confirmed) = await session.setFunctionKeys(mode)
        if let confirmed {
            snapshotsByID[device]?.keyboard?.functionKeys = confirmed
            broadcast()
        }
        return result
    }

    /// Sets which keys are disabled on `device`.
    public func setDisabledKeys(_ keys: KeyboardKeys, on device: DeviceID) async -> DeviceSettingResult {
        guard authorization == .enabled else { return .writesDisabled }
        guard let session = session(for: device) else { return .unavailable }
        let (result, confirmed) = await session.setDisabledKeys(keys)
        if let confirmed {
            snapshotsByID[device]?.keyboard?.disabledKeys = confirmed
            broadcast()
        }
        return result
    }
}
