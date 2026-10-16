public import LogiDuoHIDPP

/// Connects recovery to the Logitech devices attached right now.
///
/// Only directly attached devices (Bluetooth or USB) are offered; devices behind a
/// receiver are not yet supported. With writes disabled every transport is
/// wrapped in ``ReadOnlyTransportGuard``, so not even a defect can send a write.
public enum LiveRecoveryConnector {
    /// Opens, locates and verifies every present device. Devices without a firmware
    /// identity are not offered.
    public static func endpoints(
        ledger: RestorationLedger,
        authorization: DeviceWriteAuthorization,
        timeout: Duration = .seconds(2)
    ) async -> [RecoveryEndpoint] {
        var endpoints: [RecoveryEndpoint] = []
        for descriptor in HIDDeviceMonitor.snapshot() {
            guard
                case .directDevice(_, let framing) = HIDInterfaceClassifier.role(of: descriptor),
                let raw = try? HIDDeviceMonitor.openSnapshotTransport(
                    registryID: descriptor.registryID,
                    framing: framing
                )
            else { continue }
            let transport: any HIDPPTransport =
                authorization == .enabled ? raw : ReadOnlyTransportGuard(wrapping: raw)
            let channel = HIDPPChannel(transport: transport, clock: ContinuousClock())
            await channel.start()
            guard
                case .success(let located) = await RecoveryDeviceLocator.locate(
                    via: channel,
                    deviceIndex: .direct,
                    timeout: timeout
                )
            else {
                await channel.close()
                continue
            }
            let recovery = DeviceRecovery(
                connection: channel,
                target: located.target,
                ledger: ledger,
                authorization: authorization,
                timeout: timeout
            )
            endpoints.append(RecoveryEndpoint(name: located.name, session: recovery) { await channel.close() })
        }
        return endpoints
    }
}
