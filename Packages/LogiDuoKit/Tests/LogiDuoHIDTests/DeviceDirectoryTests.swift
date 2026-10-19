import Foundation
import LogiDuoDomain
import LogiDuoHIDPP
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHID

/// Interfaces and devices on demand; every opened transport is recorded.
private final class FakeInterfaceSource: HIDInterfaceSource, @unchecked Sendable {  // Invariant: `lock`.
    let events: AsyncStream<HIDDiscoveryEvent>
    private let sink: AsyncStream<HIDDiscoveryEvent>.Continuation
    private let lock = NSLock()
    private var responders: [UInt64: FakeHIDPPTransport.Responder] = [:]
    private var opened: [FakeHIDPPTransport] = []
    private var denied = false
    private var refused = 0

    init() {
        (events, sink) = AsyncStream.makeStream()
    }

    func add(_ descriptor: HIDInterfaceDescriptor, responder: @escaping FakeHIDPPTransport.Responder) {
        lock.withLock { responders[descriptor.registryID] = responder }
        sink.yield(.added(descriptor))
    }

    func remove(_ registryID: UInt64) {
        lock.withLock { responders[registryID] = nil }
        sink.yield(.removed(registryID: registryID))
    }

    var transports: [FakeHIDPPTransport] { lock.withLock { opened } }

    /// Opens refused as macOS refuses them without Input Monitoring.
    var refusedOpens: Int { lock.withLock { refused } }

    /// Whether opens are refused with ``HIDPPTransportError/accessDenied``.
    func denyAccess(_ deny: Bool) { lock.withLock { denied = deny } }

    func transport(registryID: UInt64, framing: HIDPPFraming) throws(HIDPPTransportError) -> any HIDPPTransport {
        let isDenied = lock.withLock {
            if denied { refused += 1 }
            return denied
        }
        if isDenied { throw .accessDenied }
        guard let responder = lock.withLock({ responders[registryID] }) else { throw .disconnected }
        let transport = FakeHIDPPTransport(responder: responder)
        lock.withLock { opened.append(transport) }
        return transport
    }

    func stop() { sink.finish() }
}

@Suite("DeviceDirectory (fake interfaces)", .timeLimit(.minutes(1)))
struct DeviceDirectoryTests {
    private static func descriptor(
        registryID: UInt64,
        product: UInt16 = 0xB034,
        transport: String = "Bluetooth Low Energy",
        usages: [(UInt32, UInt32)] = [(0x1, 0x2), (0xFF43, 0x202)],
        fingerprint: String? = "link-a"
    ) -> HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(
            registryID: registryID,
            hardware: HardwareIdentifier(vendor: .logitech, product: ProductID(rawValue: product)),
            productName: "MX Master 3S",
            transport: transport,
            usages: usages.map { HIDUsage(page: $0.0, usage: $0.1) },
            maximumInputReportSize: 20,
            maximumOutputReportSize: 20,
            linkFingerprint: fingerprint
        )
    }

    private static func directory(_ source: FakeInterfaceSource) async -> DeviceDirectory<ContinuousClock> {
        let directory = DeviceDirectory(
            source: source,
            clock: ContinuousClock(),
            authorization: .disabled,
            batteryInterval: .seconds(3600)
        )
        await directory.start()
        return directory
    }

    /// Waits for a published device list matching `condition`.
    private static func await(
        _ directory: DeviceDirectory<ContinuousClock>,
        until condition: @escaping @Sendable ([DeviceSnapshot]) -> Bool
    ) async -> [DeviceSnapshot]? {
        for await snapshots in await directory.snapshots() where condition(snapshots) {
            return snapshots
        }
        return nil
    }

    @Test("a Bluetooth mouse is connected, read and published with its firmware identity")
    func directDevice() async throws {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 1), responder: FakeHIDPPDevice().responder)

        let snapshots = await Self.await(directory) { $0.first?.link == .connected }
        let mouse = try #require(snapshots?.first)

        #expect(mouse.name == "MX Master 3S")
        #expect(mouse.category == .mouse)
        #expect(mouse.transport == .bluetoothLowEnergy)
        #expect(mouse.battery == BatteryStatus(percentage: 85, isCharging: false))
        #expect(mouse.features.contains([.reprogrammableControls, .battery]))
        #expect(mouse.firmwareVersion == "RBM22.02_0009")
        #expect(mouse.id.rawValue.hasPrefix("phy."))
        await directory.stop()
    }

    @Test("a device refused for missing Input Monitoring connects once access is granted, without a relaunch")
    func accessGrantedAfterRefusal() async throws {
        let source = FakeInterfaceSource()
        source.denyAccess(true)
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 1), responder: FakeHIDPPDevice().responder)
        while source.refusedOpens == 0 { await Task.yield() }

        source.denyAccess(false)
        let connected = Task { await Self.await(directory) { $0.first?.link == .connected } }
        // The failed state lands just after the refused open returns, and a never-identified
        // device publishes nothing to wait on; repeat the grant until the retry happens.
        let grants = Task {
            while !Task.isCancelled {
                await directory.accessGranted()
                await Task.yield()
            }
        }
        let mouse = try #require(await connected.value?.first)
        grants.cancel()

        #expect(mouse.name == "MX Master 3S")
        #expect(source.refusedOpens >= 1)
        await directory.stop()
    }

    @Test("refresh retries a device whose connection gave up")
    func refreshRetriesGivenUpDevice() async throws {
        let source = FakeInterfaceSource()
        source.denyAccess(true)
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 1), responder: FakeHIDPPDevice().responder)
        while source.refusedOpens == 0 { await Task.yield() }

        source.denyAccess(false)
        let connected = Task { await Self.await(directory) { $0.first?.link == .connected } }
        // Same race as above: repeat until the failed state has landed.
        let refreshes = Task {
            while !Task.isCancelled {
                await directory.refresh()
                await Task.yield()
            }
        }
        #expect(try #require(await connected.value).count == 1)
        refreshes.cancel()
        await directory.stop()
    }

    @Test("removal marks the device unavailable; reconnecting restores it under the same identity")
    func removalAndReconnection() async throws {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 1), responder: FakeHIDPPDevice().responder)
        let first = try #require(await Self.await(directory) { $0.first?.link == .connected }?.first)

        source.remove(1)
        #expect(await Self.await(directory) { $0.first?.link == .unavailable } != nil)

        source.add(Self.descriptor(registryID: 7), responder: FakeHIDPPDevice().responder)
        let again = try #require(await Self.await(directory) { $0.first?.link == .connected })
        #expect(again.map(\.id) == [first.id])
        await directory.stop()
    }

    @Test("the same unit over another transport keeps its identity")
    func transportChange() async throws {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 1), responder: FakeHIDPPDevice().responder)
        let bluetooth = try #require(await Self.await(directory) { $0.first?.link == .connected }?.first)
        source.remove(1)

        source.add(
            Self.descriptor(registryID: 2, transport: "USB", usages: [(0xFF00, 0x2)], fingerprint: "usb-1"),
            responder: FakeHIDPPDevice().responder
        )
        let usb = try #require(
            await Self.await(directory) { $0.first?.transport == .usbWired && $0.first?.link == .connected }
        )

        #expect(usb.map(\.id) == [bluetooth.id])
        await directory.stop()
    }

    @Test("a receiver is probed slot by slot; only answering slots become devices")
    func receiverSlots() async throws {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        var paired = FakeHIDPPDevice()
        paired.deviceIndex = 2
        let pairedResponder = paired.responder
        source.add(
            Self.descriptor(
                registryID: 9,
                product: 0xC548,
                transport: "USB",
                usages: [(0xFF00, 0x2)],
                fingerprint: "bolt"
            ),
            responder: { sent in
                sent[1] == 2 ? pairedResponder(sent) : [HIDPPTestTraffic.legacyError(for: sent, code: 0x08)]
            }
        )

        let snapshots = try #require(await Self.await(directory) { $0.first?.link == .connected })

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.transport == .receiver(.bolt))
        await directory.stop()
    }

    @Test("interfaces without HID++ are never opened")
    func nonHIDPP() async {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 3, usages: [(0x1, 0x6)]), responder: { _ in [] })
        source.add(Self.descriptor(registryID: 4), responder: FakeHIDPPDevice().responder)

        _ = await Self.await(directory) { $0.first?.link == .connected }
        #expect(source.transports.count == 1)
        await directory.stop()
    }

    @Test("sleep suspends and wake reconnects")
    func sleepWake() async {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 1), responder: FakeHIDPPDevice().responder)
        _ = await Self.await(directory) { $0.first?.link == .connected }

        await directory.hostWillSleep()
        #expect(await Self.await(directory) { $0.first?.link == .asleep } != nil)
        await directory.hostDidWake()
        #expect(await Self.await(directory) { $0.first?.link == .connected } != nil)
        await directory.stop()
    }

    @Test("refresh re-reads the battery")
    func batteryRefresh() async {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        let battery = BatteryLevelBox(0x55)
        source.add(Self.descriptor(registryID: 1)) { sent in
            var device = FakeHIDPPDevice()
            device.batteryStatus = [battery.value, 0x08, 0x01, 0x00]
            return device.responder(sent)
        }
        _ = await Self.await(directory) { $0.first?.link == .connected }

        battery.value = 0x20
        await directory.refresh()

        let updated = await Self.await(directory) { $0.first?.battery?.percentage == 32 }
        #expect(updated?.first?.battery?.isCharging == true)
        await directory.stop()
    }

    @Test("pointer resolution and SmartShift are read after connecting")
    func pointerSettings() async throws {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        var device = FakeHIDPPDevice()
        device.features += [0x2201, 0x2110]
        let base = device.responder
        let dpiIndex = UInt8(device.features.count - 2)
        let smartShiftIndex = UInt8(device.features.count - 1)
        source.add(Self.descriptor(registryID: 1)) { sent in
            switch (sent[2], sent[3] >> 4) {
            case (dpiIndex, 1):
                [HIDPPTestTraffic.reply(to: sent, parameters: [0x00, 0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0, 0])]
            case (dpiIndex, 2): [HIDPPTestTraffic.reply(to: sent, parameters: [0x00, 0x03, 0xE8, 0x03, 0xE8])]
            case (smartShiftIndex, 0): [HIDPPTestTraffic.reply(to: sent, parameters: [0x02, 0x0A, 0x0A])]
            default: base(sent)
            }
        }

        let mouse = try #require(await Self.await(directory) { $0.first?.link == .connected }?.first)

        #expect(
            mouse.resolution
                == ResolutionState(
                    current: 1000,
                    range: try #require(ResolutionRange(minimum: 200, maximum: 8000, step: 50))
                )
        )
        #expect(mouse.smartShift == .automatic(sensitivity: 10))
        await directory.stop()
    }

    @Test("discovery never sends anything but reads (read-only guard in place)")
    func readOnly() async {
        let source = FakeInterfaceSource()
        let directory = await Self.directory(source)
        source.add(Self.descriptor(registryID: 1), responder: FakeHIDPPDevice().responder)
        _ = await Self.await(directory) { $0.first?.link == .connected }
        await directory.refresh()

        // ReprogControlsV4 sits at index 5 on the fake device; function 3 is setCidReporting.
        let writes = source.transports.flatMap(\.sent).filter { $0[2] == 0x05 && $0[3] >> 4 == 3 }
        #expect(writes.isEmpty)
        await directory.stop()
    }
}

/// A mutable battery level shared with a responder.
private final class BatteryLevelBox: @unchecked Sendable {  // Invariant: `lock`.
    private let lock = NSLock()
    private var stored: UInt8

    init(_ value: UInt8) { stored = value }

    var value: UInt8 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
