/// The outcome of changing a device setting.
public enum DeviceSettingResult: Hashable, Sendable {
    /// Written and confirmed by reading it back.
    case applied
    /// Device writes are disabled in this version; the preference is saved for later.
    case writesDisabled
    /// The device does not have this setting.
    case unsupported
    /// The device is not connected.
    case unavailable
    /// The write or the read-back failed.
    case failed
}

/// Changes persistent device settings.
public protocol DeviceSettingsServicing: Sendable {
    /// Sets the pointer resolution (snapped to a supported value).
    func setResolution(_ dpi: Int, on device: DeviceID) async -> DeviceSettingResult
    /// Sets the SmartShift wheel mode.
    func setSmartShift(_ mode: SmartShiftMode, on device: DeviceID) async -> DeviceSettingResult
    /// Sets what F1, F2, … do without Fn.
    func setFunctionKeys(_ mode: FunctionKeyMode, on device: DeviceID) async -> DeviceSettingResult
    /// Sets which keys are disabled.
    func setDisabledKeys(_ keys: KeyboardKeys, on device: DeviceID) async -> DeviceSettingResult
}

extension DeviceSettings {
    /// The preset after `current` in the cycle (wrapping), or the first preset.
    public func nextResolutionPreset(after current: Int?) -> Int? {
        guard !resolutionPresets.isEmpty else { return nil }
        guard let current, let index = resolutionPresets.firstIndex(of: current) else { return resolutionPresets.first }
        return resolutionPresets[(index + 1) % resolutionPresets.count]
    }
}
