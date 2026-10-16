public import LogiDuoDomain

/// Keyboard features of multi-host keyboards (verified read-only on MX Keys).
///
/// ```
/// 0x1814 ChangeHost   fn0 getHostInfo            → [hostCount, currentHost]
/// 0x40A3 FnInversion  fn0 getFnInversion(host)   → [host, state, default]   state 1 = special functions first
///                     fn1 setFnInversion(host, state) — a WRITE
/// 0x4521 DisableKeys  fn0 getCapabilities        → [mask]   (1 Caps, 2 Num, 4 Scroll Lock, 8 Insert, 16 Windows)
///                     fn1 getDisabledKeys        → [mask]
///                     fn2 setDisabledKeys(mask)  — a WRITE
/// 0x1982 Backlight2   fn0 getBacklightConfig     → [enabled, …]
/// ```
public enum KeyboardFeatures {
    /// The host (Easy-Switch channel) the keyboard is currently connected to.
    public static func currentHost(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex
    ) async throws(HIDPPRequestError) -> UInt8 {
        try await device.perform(FeatureRequest.read(deviceIndex, index, 0), timeout: nil).parameters[1]
    }

    /// What F1, F2, … do on `host`.
    public static func functionKeys(
        host: UInt8,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex
    ) async throws(HIDPPRequestError) -> FunctionKeyMode {
        let reply = try await device.perform(FeatureRequest.read(deviceIndex, index, 0, [host]), timeout: nil)
            .parameters
        return reply[1] == 0 ? .standard : .special
    }

    /// Sets the function key mode on `host` (a configuration WRITE).
    public static func setFunctionKeys(
        _ mode: FunctionKeyMode,
        host: UInt8,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex
    ) async throws(HIDPPRequestError) {
        let state: UInt8 = mode == .standard ? 0 : 1
        _ = try await device.perform(FeatureRequest.write(deviceIndex, index, 1, [host, state]), timeout: nil)
    }

    /// Keys the keyboard can disable, and keys currently disabled.
    public static func disableKeys(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex
    ) async throws(HIDPPRequestError) -> (available: KeyboardKeys, disabled: KeyboardKeys) {
        let available = try await device.perform(FeatureRequest.read(deviceIndex, index, 0), timeout: nil).parameters[0]
        let disabled = try await device.perform(FeatureRequest.read(deviceIndex, index, 1), timeout: nil).parameters[0]
        return (KeyboardKeys(rawValue: available), KeyboardKeys(rawValue: disabled & available))
    }

    /// Sets which keys are disabled (a configuration WRITE).
    public static func setDisabledKeys(
        _ keys: KeyboardKeys,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex
    ) async throws(HIDPPRequestError) {
        _ = try await device.perform(FeatureRequest.write(deviceIndex, index, 2, [keys.rawValue]), timeout: nil)
    }

    /// Whether the backlight is on.
    public static func backlight(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex
    ) async throws(HIDPPRequestError) -> BacklightState {
        let enabled = try await device.perform(FeatureRequest.read(deviceIndex, index, 0), timeout: nil).parameters[0]
        return enabled != 0 ? .on : .off
    }
}
