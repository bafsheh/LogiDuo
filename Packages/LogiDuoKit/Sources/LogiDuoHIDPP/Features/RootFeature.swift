/// The HID++ protocol version a device implements.
public struct HIDPPProtocolVersion: Hashable, Sendable, CustomStringConvertible {
    /// Major version (4 for current HID++ 2.0 devices).
    public let major: UInt8
    /// Minor version.
    public let minor: UInt8

    /// `major.minor`.
    public var description: String { "\(major).\(minor)" }
}

/// Where a feature lives in a device's feature table.
public struct FeatureLocation: Hashable, Sendable {
    /// The feature's index.
    public let index: FeatureIndex
    /// The feature type flags (obsolete, hidden, engineering, …).
    public let typeFlags: UInt8
    /// The feature version.
    public let version: UInt8
}

/// Read-only access to the Root feature (0x0000), always at index 0.
///
/// Wire layouts (HID++ 2.0):
/// ```
/// fn0 getFeature(featureID)      → params [id_hi, id_lo]            reply [index, type, version]
/// fn1 getProtocolVersion(ping)    → params [0x00, 0x00, ping]        reply [major, minor, ping]
/// ```
/// An index of 0 in a getFeature reply means the feature is absent. Both
/// functions only read; neither changes device state.
public enum RootFeature {
    private static let getFeature = FunctionID(nibble: 0)
    private static let getProtocolVersion = FunctionID(nibble: 1)

    /// The byte a HID++ 1.0 receiver echoes as the failed sub-ID for this ping.
    public static let pingByte: UInt8 = 0x5A

    /// Asks for the protocol version and checks the echoed ping byte.
    /// - Throws: ``HIDPPRequestError``; a reply with a wrong ping byte is reported as
    ///   ``HIDPPRequestError/deviceError(_:)`` with ``HIDPP20ErrorCode/unknown``.
    public static func protocolVersion(
        via performer: some HIDPPRequestPerforming,
        device: DeviceIndex,
        timeout: Duration?
    ) async throws(HIDPPRequestError) -> HIDPPProtocolVersion {
        let request = try makeRequest(device, getProtocolVersion, [0x00, 0x00, pingByte])
        let reply = try await performer.perform(request, timeout: timeout)
        guard reply.parameters[2] == pingByte else { throw .deviceError(.unknown) }
        return HIDPPProtocolVersion(major: reply.parameters[0], minor: reply.parameters[1])
    }

    /// Looks up the index of `feature`, or `nil` if the device does not have it.
    public static func location(
        of feature: FeatureID,
        via performer: some HIDPPRequestPerforming,
        device: DeviceIndex,
        timeout: Duration?
    ) async throws(HIDPPRequestError) -> FeatureLocation? {
        let request = try makeRequest(device, getFeature, feature.bytes)
        let reply = try await performer.perform(request, timeout: timeout)
        guard reply.parameters[0] != 0 || feature == .root else { return nil }
        return FeatureLocation(
            index: FeatureIndex(rawValue: reply.parameters[0]),
            typeFlags: reply.parameters[1],
            version: reply.parameters[2]
        )
    }

    /// A handshake for ``HIDPPConnection`` that only reads the protocol version.
    public static func handshake<C: Clock>(
        _ channel: HIDPPChannel<C>,
        _ device: DeviceIndex,
        _ timeout: Duration
    ) async throws(HIDPPRequestError) where C.Duration == Duration {
        _ = try await protocolVersion(via: channel, device: device, timeout: timeout)
    }

    private static func makeRequest(
        _ device: DeviceIndex,
        _ function: FunctionID,
        _ parameters: [UInt8]
    ) throws(HIDPPRequestError) -> HIDPPRequest {
        do {
            return try HIDPPRequest(
                deviceIndex: device,
                featureIndex: .root,
                function: function,
                parameters: parameters,
                kind: .read
            )
        } catch {
            throw .framing(error)
        }
    }
}
