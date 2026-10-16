import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

/// Records the 4-byte header of every report in both directions (payloads are
/// not recorded: some replies carry the unit identifier).
final class HeaderRecordingTransport: HIDPPTransport, @unchecked Sendable {  // Invariant: `log` guarded by `lock`.
    let framing: HIDPPFraming
    let events: AsyncStream<HIDPPTransportEvent>
    private let inner: any HIDPPTransport
    private let lock = NSLock()
    private var log: [String] = []

    init(wrapping inner: any HIDPPTransport) {
        self.inner = inner
        self.framing = inner.framing
        let (events, sink) = AsyncStream.makeStream(of: HIDPPTransportEvent.self)
        self.events = events
        let source = inner.events
        Task { [weak self] in
            for await event in source {
                if case .input(let bytes) = event { self?.record("RX", bytes) }
                sink.yield(event)
            }
            sink.finish()
        }
    }

    var headers: [String] { lock.withLock { log } }

    func send(_ report: [UInt8]) async throws(HIDPPTransportError) {
        record("TX", report)
        try await inner.send(report)
    }

    func close() async { await inner.close() }

    private func record(_ direction: String, _ bytes: [UInt8]) {
        let header = bytes.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
        lock.withLock { log.append("\(direction) \(header)") }
    }
}

@Suite("Hardware: traffic diagnostics (read-only)", .enabled(if: logitechEndpointPresent), .timeLimit(.minutes(2)))
struct HardwareTrafficDiagnosticTests {
    @Test("identifies every unmatched reply during an inventory read")
    func unmatchedReplies() async throws {
        for descriptor in presentHIDPPEndpoints() {
            guard case .directDevice(_, let framing) = HIDInterfaceClassifier.role(of: descriptor) else { continue }
            let raw = try HIDDeviceMonitor.openSnapshotTransport(registryID: descriptor.registryID, framing: framing)
            let recorder = HeaderRecordingTransport(wrapping: ReadOnlyTransportGuard(wrapping: raw))
            let channel = HIDPPChannel(transport: recorder, clock: ContinuousClock())
            await channel.start()
            _ = try await DeviceInventoryReader.read(via: channel, deviceIndex: .direct, timeout: .seconds(2))
            let unmatched = await channel.statistics.unmatchedReplies
            await channel.close()

            let log = recorder.headers
            var seenTX: [String: Int] = [:]
            var seenRX: [String: Int] = [:]
            for line in log {
                let key = String(line.dropFirst(3))
                if line.hasPrefix("TX") { seenTX[key, default: 0] += 1 } else { seenRX[key, default: 0] += 1 }
            }
            let duplicates = seenRX.filter { $0.value > (seenTX[$0.key] ?? 0) && !$0.key.hasSuffix(" 00") }
            let unsolicited = seenRX.keys.filter { seenTX[$0] == nil }.sorted()
            print(
                "[traffic] \(descriptor.productName ?? "?") TX=\(log.filter { $0.hasPrefix("TX") }.count)",
                "RX=\(log.filter { $0.hasPrefix("RX") }.count) unmatched=\(unmatched)"
            )
            print("[traffic]   RX headers without a matching TX header: \(unsolicited)")
            print("[traffic]   RX headers seen more often than sent: \(duplicates)")
        }
    }
}
