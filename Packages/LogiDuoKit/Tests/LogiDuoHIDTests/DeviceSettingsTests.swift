import Foundation
import LogiDuoDomain
import LogiDuoHIDPP
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHID

/// A mouse with AdjustableDPI and SmartShift that remembers what is written.
private final class PointerDevice: @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private var dpi: UInt16 = 1000
    private var wheel: [UInt8] = [0x02, 0x0A]
    private(set) var writes: [[UInt8]] = []
    private let base: FakeHIDPPTransport.Responder
    let dpiIndex: UInt8
    let smartShiftIndex: UInt8

    init() {
        var device = FakeHIDPPDevice()
        device.features += [0x2201, 0x2110]
        dpiIndex = UInt8(device.features.count - 2)
        smartShiftIndex = UInt8(device.features.count - 1)
        base = device.responder
    }

    var currentDPI: Int { lock.withLock { Int(dpi) } }

    var responder: FakeHIDPPTransport.Responder {
        { [self] sent in respond(sent) }
    }

    private func respond(_ sent: [UInt8]) -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        switch (sent[2], sent[3] >> 4) {
        case (dpiIndex, 1):
            return [HIDPPTestTraffic.reply(to: sent, parameters: [0x00, 0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0, 0])]
        case (dpiIndex, 2):
            return [
                HIDPPTestTraffic.reply(to: sent, parameters: [0x00, UInt8(dpi >> 8), UInt8(dpi & 0xFF), 0x03, 0xE8])
            ]
        case (dpiIndex, 3):
            writes.append(Array(sent[2...6]))
            dpi = UInt16(sent[5]) << 8 | UInt16(sent[6])
            return [HIDPPTestTraffic.reply(to: sent, parameters: [0x00, sent[5], sent[6]])]
        case (smartShiftIndex, 0):
            return [HIDPPTestTraffic.reply(to: sent, parameters: wheel + [0x0A])]
        case (smartShiftIndex, 1):
            writes.append(Array(sent[2...7]))
            wheel = [sent[4], sent[5]]
            return [HIDPPTestTraffic.reply(to: sent)]
        default:
            return base(sent)
        }
    }
}

/// One interface with a pointer device.
private final class SingleSource: HIDInterfaceSource, @unchecked Sendable {  // Invariant: immutable after init.
    let events: AsyncStream<HIDDiscoveryEvent>
    private let responder: FakeHIDPPTransport.Responder

    init(_ device: PointerDevice) {
        responder = device.responder
        let descriptor = HIDInterfaceDescriptor(
            registryID: 1,
            hardware: HardwareIdentifier(vendor: .logitech, product: ProductID(rawValue: 0xB034)),
            productName: "MX Master 3S",
            transport: "Bluetooth Low Energy",
            usages: [HIDUsage(page: 0xFF43, usage: 0x202)],
            maximumInputReportSize: 20,
            maximumOutputReportSize: 20,
            linkFingerprint: "link"
        )
        events = AsyncStream { $0.yield(.added(descriptor)) }
    }

    func transport(registryID: UInt64, framing: HIDPPFraming) -> any HIDPPTransport {
        FakeHIDPPTransport(responder: responder)
    }

    func stop() {}
}

@Suite("Device settings writes (fake device only)", .timeLimit(.minutes(1)))
struct DeviceSettingsTests {
    private static func connected(
        _ device: PointerDevice,
        authorization: DeviceWriteAuthorization,
        preferences: DeviceSettings = .unchanged
    ) async throws -> (DeviceDirectory<ContinuousClock>, DeviceSnapshot) {
        let directory = DeviceDirectory(
            source: SingleSource(device),
            clock: ContinuousClock(),
            authorization: authorization,
            batteryInterval: .seconds(3600)
        )
        await directory.usePreferences { _ in preferences }
        await directory.start()
        for await snapshots in await directory.snapshots() {
            if let mouse = snapshots.first, mouse.link == .connected { return (directory, mouse) }
        }
        throw CancellationError()
    }

    @Test("with writes disabled nothing is written and the result says so")
    func disabled() async throws {
        let device = PointerDevice()
        let (directory, mouse) = try await Self.connected(device, authorization: .disabled)

        #expect(await directory.setResolution(1600, on: mouse.id) == .writesDisabled)
        #expect(await directory.setSmartShift(.freeSpin, on: mouse.id) == .writesDisabled)
        #expect(device.writes.isEmpty)
        await directory.stop()
    }

    @Test("a resolution is snapped to a supported value, written and confirmed by reading back")
    func resolution() async throws {
        let device = PointerDevice()
        let (directory, mouse) = try await Self.connected(device, authorization: .enabled)

        #expect(await directory.setResolution(1234, on: mouse.id) == .applied)

        let write = try #require(device.writes.first)
        #expect(device.writes.count == 1)
        #expect(write[0] == device.dpiIndex && write[1] >> 4 == 3)
        #expect(Array(write[2...4]) == [0x00, 0x04, 0xE2])
        #expect(device.currentDPI == 1250)
        await directory.stop()
    }

    @Test("SmartShift writes the documented bytes and confirms them")
    func smartShift() async throws {
        let device = PointerDevice()
        let (directory, mouse) = try await Self.connected(device, authorization: .enabled)

        #expect(await directory.setSmartShift(.freeSpin, on: mouse.id) == .applied)

        let write = try #require(device.writes.last)
        #expect(write[0] == device.smartShiftIndex)
        #expect(write[1] >> 4 == 1)
        #expect(Array(write[2...4]) == [0x01, 0x00, 0x00])
        await directory.stop()
    }

    @Test("saved settings are replayed when the device connects (writes enabled only)")
    func replay() async throws {
        let device = PointerDevice()
        let saved = DeviceSettings(resolution: 1600, resolutionPresets: [], smartShift: nil)
        let (directory, _) = try await Self.connected(device, authorization: .enabled, preferences: saved)

        #expect(await eventually { device.currentDPI == 1600 })
        await directory.stop()

        let untouched = PointerDevice()
        let (disabled, _) = try await Self.connected(untouched, authorization: .disabled, preferences: saved)
        #expect(untouched.writes.isEmpty)
        await disabled.stop()
    }

    @Test("an unknown device is unavailable")
    func unavailable() async throws {
        let (directory, _) = try await Self.connected(PointerDevice(), authorization: .enabled)
        #expect(await directory.setResolution(800, on: .fixture(9)) == .unavailable)
        await directory.stop()
    }

    @Test("cycling presets wraps around and starts at the first for unknown values")
    func presets() {
        let settings = DeviceSettings(resolution: nil, resolutionPresets: [800, 1600, 3200], smartShift: nil)
        #expect(settings.nextResolutionPreset(after: 800) == 1600)
        #expect(settings.nextResolutionPreset(after: 3200) == 800)
        #expect(settings.nextResolutionPreset(after: 1000) == 800)
        #expect(
            DeviceSettings(resolution: nil, resolutionPresets: [], smartShift: nil).nextResolutionPreset(after: 800)
                == nil
        )
    }
}
