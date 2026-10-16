import Foundation
import IOKit.hid
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

/// Raw, read-only framing probe: Root getProtocolVersion pings only.
///
/// Records what the HID stack actually delivers (length, whether byte 0 is
/// the report ID) and whether the device echoes the request's software ID.
@Suite(
    "Hardware: raw framing probe (read-only)",
    .enabled(if: logitechEndpointPresent),
    .serialized,
    .timeLimit(.minutes(2))
)
struct HardwareFramingProbeTests {
    /// Root fn1 getProtocolVersion with ping byte 0x5A and software ID `softwareID`.
    private static func ping(softwareID: UInt8) -> [UInt8] {
        [0x11, 0xFF, 0x00, 0x10 | softwareID, 0x00, 0x00, 0x5A] + Array(repeating: 0, count: 13)
    }

    /// Collects raw input buffers for `window`.
    private static func collect(_ transport: some HIDPPTransport, window: Duration) async -> [[UInt8]] {
        let collector = Task {
            var buffers: [[UInt8]] = []
            for await event in transport.events {
                if case .input(let bytes) = event { buffers.append(bytes) }
            }
            return buffers
        }
        try? await ContinuousClock().sleep(for: window)
        await transport.close()
        return await collector.value
    }

    @Test("reports open result, raw reply framing and software-ID echo per endpoint")
    func framing() async throws {
        for descriptor in presentHIDPPEndpoints() {
            guard case .directDevice(_, let framing) = HIDInterfaceClassifier.role(of: descriptor) else { continue }
            let name = descriptor.productName ?? "?"
            let raw: IOKitHIDTransport
            do {
                raw = try HIDDeviceMonitor.openSnapshotTransport(registryID: descriptor.registryID, framing: framing)
            } catch {
                print("[framing] \(descriptor.hardware) \(name) open FAILED: \(error)")
                Issue.record("open failed for \(name): \(error)")
                continue
            }
            print("[framing] \(descriptor.hardware) \(name) open OK (non-exclusive)")
            let guarded = ReadOnlyTransportGuard(wrapping: raw)
            let sentIDs: [UInt8] = [0x01, 0x0A, 0x0F]
            let collecting = Task { await Self.collect(guarded, window: .seconds(2)) }
            for softwareID in sentIDs {
                try await guarded.send(Self.ping(softwareID: softwareID))
            }
            let buffers = await collecting.value
            #expect(guarded.refusedReports == 0)

            let replies = buffers.filter { $0.count >= 7 && $0[2] == 0x00 && $0[3] >> 4 == 1 }
            for buffer in buffers {
                let shown = buffer.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                print("[framing]   len=\(buffer.count) first=0x\(String(format: "%02X", buffer[0])) head=\(shown)")
            }
            let echoed = replies.map { $0[3] & 0x0F }
            print("[framing]   ping replies=\(replies.count) echoedSW=\(echoed) sent=\(sentIDs)")
            // Ordinary input reports (0x01/0x02 mouse, keyboard) share the interface over Bluetooth.
            #expect(replies.allSatisfy { $0.first == 0x11 || $0.first == 0x10 || $0.first == 0x12 })
            // Investigation record: back-to-back pings are expected to lose requests if the
            // device keeps only one outstanding request; see `sequentialEcho`.
            print("[framing]   pipelined: \(Set(echoed) == Set(sentIDs) ? "all answered" : "requests lost")")
        }
    }

    @Test("echoes each software ID when requests are sent one at a time")
    func sequentialEcho() async throws {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        print("[framing] Input Monitoring access for this process: \(access.rawValue) (0 granted, 1 denied, 2 unknown)")
        for descriptor in presentHIDPPEndpoints() {
            guard case .directDevice(_, let framing) = HIDInterfaceClassifier.role(of: descriptor) else { continue }
            let raw = try HIDDeviceMonitor.openSnapshotTransport(registryID: descriptor.registryID, framing: framing)
            let guarded = ReadOnlyTransportGuard(wrapping: raw)
            var events = guarded.events.makeAsyncIterator()
            var echoed: [UInt8] = []
            for softwareID: UInt8 in [0x01, 0x05, 0x0A, 0x0F] {
                try await guarded.send(Self.ping(softwareID: softwareID))
                let reply = await Self.nextPingReply(&events, within: .seconds(1))
                echoed.append(reply.map { $0[3] & 0x0F } ?? 0)
            }
            await guarded.close()
            print("[framing] \(descriptor.productName ?? "?") sequential sent=[1, 5, 10, 15] echoed=\(echoed)")
            #expect(echoed == [0x01, 0x05, 0x0A, 0x0F])
            #expect(guarded.refusedReports == 0)
        }
    }

    /// The next Root getProtocolVersion reply, or `nil` after `window`.
    private static func nextPingReply(
        _ events: inout AsyncStream<HIDPPTransportEvent>.Iterator,
        within window: Duration
    ) async -> [UInt8]? {
        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline {
            guard let event = await events.next() else { return nil }
            if case .input(let bytes) = event, bytes.count == 20, bytes[2] == 0x00, bytes[3] >> 4 == 1 {
                return bytes
            }
        }
        return nil
    }
}
