/// A temporary reporting change for one control.
///
/// There is deliberately no way to express a *persistent* divert: LogiDuo never
/// stores configuration in device memory, so every change is undone by a device
/// reset at the latest.
public struct ReportingChange: Hashable, Sendable {
    /// Divert the control's presses to the host.
    public let divert: Bool
    /// Also divert raw XY movement while the control is held.
    public let rawXY: Bool

    /// Creates a change.
    public init(divert: Bool, rawXY: Bool) {
        self.divert = divert
        self.rawXY = rawXY && divert
    }

    /// Native reporting: not diverted.
    public static let native = ReportingChange(divert: false, rawXY: false)

    /// The setCidReporting flags byte: divert/valid (bits 0–1) and raw XY/valid (bits 4–5).
    /// The persistent bits (2–3) are never set.
    var flagsByte: UInt8 {
        0x02 | 0x20 | (divert ? 0x01 : 0) | (rawXY ? 0x10 : 0)
    }

    /// Whether `reporting` is exactly this change's state.
    func matches(_ reporting: ControlReporting) -> Bool {
        reporting.isDiverted == divert && reporting.isRawXYDiverted == rawXY && !reporting.isPersistentlyDiverted
    }
}

extension ReprogControlsFeature {
    /// Changes a control's temporary reporting (setCidReporting, fn3). A **write**.
    ///
    /// Layout: `[cid hi, cid lo, flags, remap hi, remap lo]`; remap 0 leaves any remapping unchanged.
    public static func setReporting(
        of control: UInt16,
        to change: ReportingChange,
        via device: some HIDPPRequestPerforming,
        index: FeatureIndex,
        deviceIndex: DeviceIndex,
        timeout: Duration? = nil
    ) async throws(HIDPPRequestError) {
        let request: HIDPPRequest
        do {
            request = try HIDPPRequest(
                deviceIndex: deviceIndex,
                featureIndex: index,
                function: FunctionID(nibble: 3),
                parameters: [UInt8(control >> 8), UInt8(control & 0xFF), change.flagsByte, 0x00, 0x00],
                kind: .write
            )
        } catch {
            throw .framing(error)
        }
        _ = try await device.perform(request, timeout: timeout)
    }
}
