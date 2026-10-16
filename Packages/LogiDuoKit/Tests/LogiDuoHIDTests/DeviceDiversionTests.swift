import Foundation
import LogiDuoDomain
import LogiDuoHIDPP
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHID

/// A mouse whose ReprogControls (served at index 9) comes from ``FakeReprogDevice``
/// (which answers on index 1) and everything else from ``FakeHIDPPDevice``.
private final class DivertingMouse: HIDInterfaceSource, @unchecked Sendable {  // Invariant: `lock`.
    let device = FakeReprogDevice()
    let events: AsyncStream<HIDDiscoveryEvent>
    private let lock = NSLock()
    private var opened: [FakeHIDPPTransport] = []
    private let inventory = FakeHIDPPDevice()

    init() {
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

    var transport: FakeHIDPPTransport? { lock.withLock { opened.last } }

    func transport(registryID: UInt64, framing: HIDPPFraming) -> any HIDPPTransport {
        let reprog = device.responder
        let rest = inventory.responder
        let transport = FakeHIDPPTransport { sent in
            if sent[2] == 0x00, sent[3] >> 4 == 0, sent[4] == 0x1B, sent[5] == 0x04 {
                return [HIDPPTestTraffic.reply(to: sent, parameters: [0x09, 0, 5])]
            }
            guard sent[2] == 0x09 else { return rest(sent) }
            var translated = sent
            translated[2] = 0x01
            return reprog(translated).map { reply in
                var reply = reply
                if reply[2] == 0x01 { reply[2] = 0x09 } else if reply[2] == 0xFF, reply[3] == 0x01 { reply[3] = 0x09 }
                return reply
            }
        }
        lock.withLock { opened.append(transport) }
        return transport
    }

    func stop() {}
}

/// Collects device input events.
private actor InputLog {
    var events: [InputEvent] = []
    func append(_ event: InputEvent) { events.append(event) }
}

@Suite("Device diversion through the directory (fake device only)", .timeLimit(.minutes(1)))
struct DeviceDiversionTests {
    private static func connected(
        _ mouse: DivertingMouse,
        authorization: DeviceWriteAuthorization,
        store: InMemoryJournalStore = InMemoryJournalStore(),
        buttons: Set<MouseButton> = [.gesture],
        log: InputLog = InputLog()
    ) async throws -> DeviceDirectory<ContinuousClock> {
        let ledger = RestorationLedger(store: store)
        _ = await ledger.load()
        let directory = DeviceDirectory(
            source: mouse,
            clock: ContinuousClock(),
            authorization: authorization,
            ledger: ledger,
            batteryInterval: .seconds(3600)
        )
        await directory.useDeviceInput { event in await log.append(event) }
        await directory.setDiversion(buttons)
        await directory.start()
        for await snapshots in await directory.snapshots() where snapshots.first?.link == .connected {
            return directory
        }
        throw CancellationError()
    }

    @Test("with authorization, the gesture button is diverted through the journal after connecting")
    func diverts() async throws {
        let mouse = DivertingMouse()
        let store = InMemoryJournalStore()
        let directory = try await Self.connected(mouse, authorization: .enabled, store: store)

        #expect(await eventually { mouse.device.reportingFlags(of: 0x00C3) == 0x11 })
        #expect(mouse.device.writeLog.map(\.1) == [0x33])
        #expect(store.persisted.entries.count == 1)
        await directory.stop()
        #expect(mouse.device.reportingFlags(of: 0x00C3) == 0)
        #expect(store.persisted.isClean)
    }

    @Test("without authorization nothing is diverted, whatever the mappings ask")
    func disabled() async throws {
        let mouse = DivertingMouse()
        let directory = try await Self.connected(mouse, authorization: .disabled)
        await directory.setDiversion([.gesture, .modeShift])
        await directory.stop()
        #expect(mouse.device.writeLog.isEmpty)
    }

    @Test("diverted button notifications become input events; a disconnect releases held buttons")
    func notifications() async throws {
        let mouse = DivertingMouse()
        let log = InputLog()
        let directory = try await Self.connected(mouse, authorization: .enabled, log: log)
        #expect(await eventually { mouse.device.reportingFlags(of: 0x00C3) == 0x11 })
        let transport = try #require(mouse.transport)

        transport.deliver(HIDPPTestTraffic.notification(feature: 0x09, function: 0, parameters: [0x00, 0xC3]))
        transport.deliver(
            HIDPPTestTraffic.notification(feature: 0x09, function: 1, parameters: [0x00, 0x05, 0xFF, 0xFF])
        )
        #expect(await eventually { await log.events.count == 2 })
        #expect(await log.events == [.buttonDown(.gesture), .motion(dx: 5, dy: -1, source: .deviceRawXY)])

        await directory.stop()
        #expect(await log.events.last == .buttonUp(.gesture))
    }

    @Test("dropping a button from the mappings restores it")
    func shrink() async throws {
        let mouse = DivertingMouse()
        let store = InMemoryJournalStore()
        let directory = try await Self.connected(
            mouse,
            authorization: .enabled,
            store: store,
            buttons: [.gesture, .modeShift]
        )
        #expect(await eventually { mouse.device.reportingFlags(of: 0x00C4) == 0x01 })

        await directory.setDiversion([.gesture])

        #expect(mouse.device.reportingFlags(of: 0x00C4) == 0)
        #expect(mouse.device.reportingFlags(of: 0x00C3) == 0x11)
        #expect(store.persisted.entries.map(\.setting) == [.controlReporting(DeviceControlID(rawValue: 0x00C3))])
        await directory.stop()
    }
}

@Suite("Device diversion review regressions (fake device only)", .timeLimit(.minutes(1)))
struct DeviceDiversionRegressionTests {
    @Test("regression: a shared ledger that nobody loaded keeps the earlier run's records")
    func lazyLedgerLoad() async throws {
        let store = InMemoryJournalStore()
        let earlier = RestorationLedger(store: store)
        try await earlier.record(
            .controlReporting(DeviceControlID(rawValue: 0x00C4)),
            on: .fixture(1),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )

        let shared = RestorationLedger(store: store)  // never loaded explicitly
        try await shared.record(
            .controlReporting(DeviceControlID(rawValue: 0x00C3)),
            on: .fixture(1),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )

        #expect(store.persisted.entries.count == 2)
        #expect(await shared.load() == .pending(entries: 2))
    }

    @Test("regression: loading twice never turns this run's records into inherited ones")
    func loadIsIdempotent() async throws {
        let ledger = RestorationLedger(store: InMemoryJournalStore())
        _ = await ledger.load()
        try await ledger.record(
            .controlReporting(DeviceControlID(rawValue: 0x00C3)),
            on: .fixture(1),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )
        _ = await ledger.load()
        #expect(await !ledger.hasInheritedEntries(.fixture(1)))
    }

    @Test("regression: connecting never restores records left by an earlier run")
    func earlierRunUntouched() async throws {
        let mouse = DivertingMouse()
        mouse.device.setReportingFlags(0x01, of: 0x00C4)
        let store = InMemoryJournalStore()
        try await RestorationLedger(store: store).record(
            .controlReporting(DeviceControlID(rawValue: 0x00C4)),
            on: DeviceID(physical: try #require(Self.physical)),
            original: .controlReporting(diverted: false, rawXYDiverted: false)
        )
        let ledger = RestorationLedger(store: store)
        let directory = DeviceDirectory(
            source: mouse,
            clock: ContinuousClock(),
            authorization: .enabled,
            ledger: ledger,
            batteryInterval: .seconds(3600)
        )
        await directory.start()
        for await snapshots in await directory.snapshots() where snapshots.first?.link == .connected { break }
        await directory.setDiversion([])
        await directory.stop()

        #expect(mouse.device.writeLog.isEmpty)
        #expect(mouse.device.reportingFlags(of: 0x00C4) == 0x01)
        #expect(store.persisted.entries.count == 1)
    }

    /// The identity FakeHIDPPDevice reports (unit DEADBEEF, model B0344082 0000).
    private static var physical: PhysicalDeviceID? {
        ModelID(rawValue: 0xB034_4082_0000).map { PhysicalDeviceID(model: $0, unit: UnitID(rawValue: 0xDEAD_BEEF)) }
    }
}
