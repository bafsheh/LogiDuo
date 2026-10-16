/// Whether a request only reads device state.
///
/// Only reads are retried automatically: repeating a write could apply a
/// change twice or interleave with a user action.
public enum HIDPPRequestKind: Hashable, Sendable {
    /// Reads state; safe to repeat.
    case read
    /// Changes state; never repeated automatically.
    case write
}

/// A HID++ 2.0 request to one function of one feature.
public struct HIDPPRequest: Hashable, Sendable {
    /// The addressed device.
    public let deviceIndex: DeviceIndex
    /// The feature index on that device.
    public let featureIndex: FeatureIndex
    /// The function to call.
    public let function: FunctionID
    /// The parameters (at most the long-report payload capacity).
    public let parameters: [UInt8]
    /// Whether the request reads or writes.
    public let kind: HIDPPRequestKind

    /// Creates a request, rejecting parameters that do not fit a long report.
    public init(
        deviceIndex: DeviceIndex,
        featureIndex: FeatureIndex,
        function: FunctionID,
        parameters: [UInt8] = [],
        kind: HIDPPRequestKind
    ) throws(HIDPPFrameError) {
        guard parameters.count <= HIDPPReportType.long.payloadCapacity else {
            throw .payloadTooLong(capacity: HIDPPReportType.long.payloadCapacity, actual: parameters.count)
        }
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.function = function
        self.parameters = parameters
        self.kind = kind
    }

    /// The long report for this request with `softwareID`.
    public func report(softwareID: SoftwareID) -> HIDPPReport {
        do {
            return try HIDPPReport(
                type: .long,
                deviceIndex: deviceIndex,
                subID: featureIndex.rawValue,
                address: function.rawValue << 4 | softwareID.rawValue,
                payload: parameters
            )
        } catch {
            // Unreachable: the initializer already bounded the parameters.
            preconditionFailure("validated parameters exceed long payload: \(error)")
        }
    }
}
