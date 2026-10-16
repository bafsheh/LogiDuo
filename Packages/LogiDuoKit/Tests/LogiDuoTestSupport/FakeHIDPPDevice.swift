/// Emulates the read-only HID++ 2.0 functions of a device, for use as a
/// ``FakeHIDPPTransport`` responder.
///
/// Feature table (indexes are arbitrary but fixed):
/// `0 Root, 1 FeatureSet, 2 DeviceInformation, 3 DeviceName, 4 UnifiedBattery, 5 ReprogControlsV4`.
public struct FakeHIDPPDevice: Sendable {
    /// The emulated features, in index order (index 0 is Root).
    public var features: [UInt16] = [0x0000, 0x0001, 0x0003, 0x0005, 0x1004, 0x1B04]
    /// The name returned by DeviceName.
    public var name = "MX Master 3S"
    /// The device type code.
    public var typeCode: UInt8 = 3
    /// getDeviceInfo parameters.
    public var deviceInfo: [UInt8] = [
        0x02, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x0E, 0xB0, 0x34, 0x40, 0x82, 0x00, 0x00, 0x00, 0x00,
    ]
    /// getFwInfo parameters per entity.
    public var firmware: [[UInt8]] = [
        [0x00, 0x52, 0x42, 0x4D, 0x22, 0x02, 0x00, 0x09, 0x01],
        [0x01, 0x42, 0x4F, 0x54, 0x01, 0x05, 0x00, 0x12, 0x00],
    ]
    /// UnifiedBattery getStatus parameters.
    public var batteryStatus: [UInt8] = [0x55, 0x08, 0x00, 0x00]
    /// The device index this device answers on.
    public var deviceIndex: UInt8 = 0xFF
    /// ReprogControlsV4 controls: getCidInfo parameters per index (cid, task, flags lo, pos, group, gmask, flags hi).
    public var controls: [[UInt8]] = [
        [0x00, 0x52, 0x00, 0x38, 0x31, 0x00, 0x01, 0x01, 0x00],
        [0x00, 0xC3, 0x00, 0xAD, 0x70, 0x00, 0x05, 0x00, 0x03],
    ]
    /// getCidReporting parameters per control id.
    public var reporting: [UInt16: [UInt8]] = [0x0052: [0x00, 0x52, 0x00, 0x00, 0x00, 0x00]]

    /// Creates the default emulated device.
    public init() {}

    /// A responder answering the emulated functions and returning HID++ errors otherwise.
    public var responder: FakeHIDPPTransport.Responder {
        let device = self
        return { sent in device.respond(to: sent) }
    }

    func respond(to sent: [UInt8]) -> [[UInt8]] {
        guard sent.count == 20, sent[1] == deviceIndex else { return [] }
        let index = Int(sent[2])
        let function = sent[3] >> 4
        guard index < features.count else { return [HIDPPTestTraffic.featureError(for: sent, code: 0x06)] }
        guard let parameters = parameters(feature: features[index], function: function, request: sent) else {
            return [HIDPPTestTraffic.featureError(for: sent, code: 0x07)]
        }
        return [HIDPPTestTraffic.reply(to: sent, parameters: parameters)]
    }

    private func parameters(feature: UInt16, function: UInt8, request: [UInt8]) -> [UInt8]? {
        switch (feature, function) {
        case (0x0000, 0):
            let wanted = UInt16(request[4]) << 8 | UInt16(request[5])
            return [UInt8(features.firstIndex(of: wanted) ?? 0), 0x00, 0x01]
        case (0x0000, 1): return [0x04, 0x05, request[6]]
        case (0x0001, 0): return [UInt8(features.count - 1)]
        case (0x0001, 1):
            let id = features[Int(request[4])]
            return [UInt8(id >> 8), UInt8(id & 0xFF), 0x00, 0x01]
        case (0x0003, 0): return deviceInfo
        case (0x0003, 1): return firmware[Int(request[4])]
        case (0x0005, 0): return [UInt8(name.utf8.count)]
        case (0x0005, 1): return Array(Array(name.utf8).dropFirst(Int(request[4])).prefix(16))
        case (0x0005, 2): return [typeCode]
        case (0x1004, 1): return batteryStatus
        case (0x1B04, 0): return [UInt8(controls.count)]
        case (0x1B04, 1): return Int(request[4]) < controls.count ? controls[Int(request[4])] : nil
        case (0x1B04, 2):
            let cid = UInt16(request[4]) << 8 | UInt16(request[5])
            return reporting[cid] ?? [request[4], request[5], 0x00, 0x00, 0x00, 0x00]
        default: return nil
        }
    }
}
