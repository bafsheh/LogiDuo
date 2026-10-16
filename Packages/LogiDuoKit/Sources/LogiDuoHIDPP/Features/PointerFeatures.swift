public import LogiDuoDomain

/// AdjustableDPI (0x2201), sensor 0.
///
/// ```
/// fn1 getSensorDpiList(sensor) → [sensor, dpi(2)…, 0]   a value ≥ 0xE000 is a step (low 13 bits)
///                                                        between the values on either side
/// fn2 getSensorDpi(sensor)     → [sensor, dpi(2), default dpi(2)]
/// fn3 setSensorDpi(sensor, dpi(2)) — a WRITE
/// ```
public enum AdjustableDPIFeature {
    /// The supported resolutions as a range, if the device lists a stepped range.
    public static func supportedRange(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> ResolutionRange? {
        let reply = try await device.perform(FeatureRequest.read(deviceIndex, index, 1, [0]), timeout: timeout)
            .parameters
        return parseRange(Array(reply.dropFirst()))
    }

    /// The current resolution in DPI.
    public static func current(
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> Int {
        let reply = try await device.perform(FeatureRequest.read(deviceIndex, index, 2, [0]), timeout: timeout)
            .parameters
        return Int(FeatureRequest.bigEndian(reply[1...2], as: UInt16.self))
    }

    /// Sets the resolution (a configuration WRITE; callers must hold write authorization).
    /// - Returns: The resolution the device echoed.
    public static func set(
        _ dpi: Int,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> Int {
        let value = UInt16(clamping: dpi)
        let request = try FeatureRequest.write(deviceIndex, index, 3, [0, UInt8(value >> 8), UInt8(value & 0xFF)])
        let reply = try await device.perform(request, timeout: timeout).parameters
        return Int(FeatureRequest.bigEndian(reply[1...2], as: UInt16.self))
    }

    /// Parses a DPI list: plain values, or `low, 0xE000|step, high` ranges.
    static func parseRange(_ bytes: [UInt8]) -> ResolutionRange? {
        var values: [UInt16] = []
        var offset = 0
        while offset + 1 < bytes.count {
            let value = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            if value == 0 { break }
            values.append(value)
            offset += 2
        }
        if values.count >= 3, let stepIndex = values.firstIndex(where: { $0 >= 0xE000 }), stepIndex > 0,
            stepIndex + 1 < values.count
        {
            let step = Int(values[stepIndex] & 0x1FFF)
            return ResolutionRange(minimum: Int(values[stepIndex - 1]), maximum: Int(values[stepIndex + 1]), step: step)
        }
        guard let low = values.first, let high = values.last, values.count >= 2 else { return nil }
        let steps = zip(values, values.dropFirst()).map { Int($1) - Int($0) }
        guard let step = steps.first, steps.allSatisfy({ $0 == step }) else { return nil }
        return ResolutionRange(minimum: Int(low), maximum: Int(high), step: step)
    }
}

/// SmartShift wheel mode: 0x2110 (basic) and 0x2111 (enhanced).
///
/// ```
/// 0x2110 fn0 getRatchetControlMode → [wheelMode, autoDisengage, autoDisengageDefault]
///        fn1 setRatchetControlMode(wheelMode, autoDisengage, 0) — a WRITE
/// 0x2111 fn1 getRatchetControlMode → [wheelMode, autoDisengage, torque]
///        fn2 setRatchetControlMode(wheelMode, autoDisengage, torque) — a WRITE
/// wheelMode 1 = free spin, 2 = ratchet; autoDisengage 1–50 = SmartShift threshold, 0xFF = always ratchet
/// ```
public enum SmartShiftFeature {
    /// Thresholds LogiDuo uses (matching Mouser and Logi Options+).
    public static let sensitivities: ClosedRange<Int> = 1...50

    /// The current mode.
    public static func mode(
        feature: FeatureID,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) -> SmartShiftMode {
        let function: UInt8 = feature == .smartShiftEnhanced ? 1 : 0
        let reply = try await device.perform(FeatureRequest.read(deviceIndex, index, function), timeout: timeout)
            .parameters
        return decode(mode: reply[0], autoDisengage: reply[1])
    }

    /// Sets the mode (a configuration WRITE; callers must hold write authorization).
    public static func set(
        _ mode: SmartShiftMode,
        feature: FeatureID,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) {
        let function: UInt8 = feature == .smartShiftEnhanced ? 2 : 1
        let request = try FeatureRequest.write(deviceIndex, index, function, encode(mode) + [0])
        _ = try await device.perform(request, timeout: timeout)
    }

    /// The wheel mode and auto-disengage bytes for `mode`.
    static func encode(_ mode: SmartShiftMode) -> [UInt8] {
        switch mode {
        case .freeSpin: [0x01, 0x00]
        case .ratchet: [0x02, 0xFF]
        case .automatic(let sensitivity):
            [0x02, UInt8(min(max(sensitivity, sensitivities.lowerBound), sensitivities.upperBound))]
        }
    }

    /// The mode for raw bytes. Free spin keeps its stored threshold, which does not apply.
    static func decode(mode: UInt8, autoDisengage: UInt8) -> SmartShiftMode {
        if mode == 0x01 { return .freeSpin }
        return sensitivities.contains(Int(autoDisengage)) ? .automatic(sensitivity: Int(autoDisengage)) : .ratchet
    }
}
