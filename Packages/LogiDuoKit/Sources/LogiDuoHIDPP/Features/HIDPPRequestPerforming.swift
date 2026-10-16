/// Something that can perform a HID++ request and return its reply.
///
/// Implemented by ``HIDPPChannel`` (one transport) and ``HIDPPConnection``
/// (a managed device connection), so feature clients work with either.
public protocol HIDPPRequestPerforming: Sendable {
    /// Sends `request` and returns the correlated reply.
    func perform(_ request: HIDPPRequest, timeout: Duration?) async throws(HIDPPRequestError) -> HIDPPMessage
}

extension HIDPPChannel: HIDPPRequestPerforming {
    /// Sends `request`, waiting up to `timeout` (two seconds if `nil`).
    public func perform(_ request: HIDPPRequest, timeout: Duration?) async throws(HIDPPRequestError) -> HIDPPMessage {
        try await send(request, timeout: timeout ?? .seconds(2))
    }
}

extension HIDPPConnection: HIDPPRequestPerforming {}

/// Builds requests for feature clients.
enum FeatureRequest {
    static func read(
        _ device: DeviceIndex,
        _ feature: FeatureIndex,
        _ function: UInt8,
        _ parameters: [UInt8] = []
    ) throws(HIDPPRequestError) -> HIDPPRequest {
        do {
            return try HIDPPRequest(
                deviceIndex: device,
                featureIndex: feature,
                function: FunctionID(nibble: function),
                parameters: parameters,
                kind: .read
            )
        } catch {
            throw .framing(error)
        }
    }

    /// A configuration write. Only device-setting clients use this, behind write authorization.
    static func write(
        _ device: DeviceIndex,
        _ feature: FeatureIndex,
        _ function: UInt8,
        _ parameters: [UInt8]
    ) throws(HIDPPRequestError) -> HIDPPRequest {
        do {
            return try HIDPPRequest(
                deviceIndex: device,
                featureIndex: feature,
                function: FunctionID(nibble: function),
                parameters: parameters,
                kind: .write
            )
        } catch {
            throw .framing(error)
        }
    }

    /// Big-endian unsigned integer from `bytes`.
    static func bigEndian<T: FixedWidthInteger & UnsignedInteger>(_ bytes: ArraySlice<UInt8>, as _: T.Type) -> T {
        bytes.reduce(T.zero) { $0 << 8 | T($1) }
    }
}
