import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import Testing

/// Live, read-only HID++ verification against connected Logitech devices.
///
/// Every request goes through ``ReadOnlyTransportGuard``; the suite asserts the
/// guard refused nothing, so no non-allow-listed byte sequence was produced.
/// Unit identifiers are never printed.
@Suite("Hardware: read-only HID++ queries", .enabled(if: logitechEndpointPresent), .timeLimit(.minutes(2)))
struct HardwareReadOnlyTests {
    /// Applications that may compete for the device or change its configuration.
    private static let competingProcesses = ["Mouser", "logioptionsplus_agent", "LogiOptionsPlus", "lghub_agent"]

    private static func runningCompetitors() -> [String] {
        competingProcesses.filter { name in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
    }

    private static func withGuardedChannel<T: Sendable>(
        _ descriptor: HIDInterfaceDescriptor,
        _ body: (HIDPPChannel<ContinuousClock>, ReadOnlyTransportGuard) async throws -> T
    ) async throws -> T {
        guard case .directDevice(_, let framing) = HIDInterfaceClassifier.role(of: descriptor) else {
            throw HIDPPTransportError.blockedByPolicy
        }
        let raw = try HIDDeviceMonitor.openSnapshotTransport(registryID: descriptor.registryID, framing: framing)
        let guardTransport = ReadOnlyTransportGuard(wrapping: raw)
        let channel = HIDPPChannel(transport: guardTransport, clock: ContinuousClock())
        await channel.start()
        do {
            let result = try await body(channel, guardTransport)
            await channel.close()
            return result
        } catch {
            await channel.close()
            throw error
        }
    }

    @Test("no competing Logitech configuration software is running")
    func preconditions() {
        #expect(Self.runningCompetitors().isEmpty)
    }

    @Test("reads the inventory of every HID++ endpoint through the read-only guard")
    func inventory() async throws {
        try #require(Self.runningCompetitors().isEmpty)
        for descriptor in presentHIDPPEndpoints() {
            let started = ContinuousClock.now
            let outcome = try await Self.withGuardedChannel(descriptor) { channel, guardTransport in
                let inventory = try await DeviceInventoryReader.read(
                    via: channel,
                    deviceIndex: .direct,
                    timeout: .seconds(2)
                )
                return (inventory, guardTransport.refusedReports, await channel.statistics)
            }
            let (inventory, refused, statistics) = outcome
            print("[hardware] \(descriptor.hardware) \(Self.summary(inventory))")
            print("[hardware]   elapsed=\(ContinuousClock.now - started) malformed=\(statistics.malformedReports)")
            print("[hardware]   unmatched=\(statistics.unmatchedReplies) refused=\(refused)")
            #expect(refused == 0)
            #expect(statistics.malformedReports == 0)
            #expect(inventory.protocolVersion.major >= 2)
        }
    }

    /// A redacted, single-line description of an inventory (no unit identifier).
    private static func summary(_ inventory: HIDPPDeviceInventory) -> String {
        let features = inventory.features.map { "\($0.feature)@\($0.index)v\($0.version)" }
        let battery = inventory.battery.map { reading in
            "\(reading.percentage.map(String.init) ?? "?")% status=\(reading.chargingStatusCode) via \(reading.source)"
        }
        return [
            "name=\(inventory.name ?? "?") type=\(inventory.typeCode.map(String.init) ?? "?")",
            "protocol=\(inventory.protocolVersion) firmware=\(inventory.firmware.map(\.description))",
            "model=\(inventory.information?.physicalID?.model.description ?? "?") unit=redacted",
            "battery=\(battery ?? "none") features(\(features.count))=\(features)",
        ].joined(separator: " ")
    }

    @Test("repeated open, ping and close cycles leave the device responsive")
    func repeatedCycles() async throws {
        try #require(Self.runningCompetitors().isEmpty)
        let descriptor = try #require(presentHIDPPEndpoints().first)
        for _ in 0..<5 {
            let version = try await Self.withGuardedChannel(descriptor) { channel, _ in
                try await RootFeature.protocolVersion(via: channel, device: .direct, timeout: .seconds(2))
            }
            #expect(version.major >= 2)
        }
    }
}
