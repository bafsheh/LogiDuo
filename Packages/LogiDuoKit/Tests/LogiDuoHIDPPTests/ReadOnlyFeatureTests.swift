import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("Read-only device inventory", .timeLimit(.minutes(1)))
struct DeviceInventoryTests {
    private func channel(_ device: FakeHIDPPDevice = FakeHIDPPDevice()) async -> HIDPPChannel<ManualClock> {
        let channel = HIDPPChannel(transport: FakeHIDPPTransport(responder: device.responder), clock: ManualClock())
        await channel.start()
        return channel
    }

    @Test("reads protocol version, name, type, feature table, identity, firmware and battery")
    func fullInventory() async throws {
        let inventory = try await DeviceInventoryReader.read(via: await channel(), deviceIndex: .direct)

        #expect(inventory.protocolVersion == HIDPPProtocolVersion(major: 4, minor: 5))
        #expect(inventory.name == "MX Master 3S")
        #expect(inventory.typeCode == 3)
        #expect(
            inventory.features.map(\.feature) == [
                .root, .featureSet, .deviceInformation, .deviceName, .unifiedBattery, .reprogControlsV4,
            ]
        )
        #expect(inventory.supports(.reprogControlsV4))
        #expect(
            inventory.information?.physicalID
                == PhysicalDeviceID(
                    model: try #require(ModelID(rawValue: 0xB034_4082_0000)),
                    unit: UnitID(rawValue: 0xDEAD_BEEF)
                )
        )
        #expect(inventory.firmware.map(\.description) == ["RBM22.02_0009", "BOT01.05_0012"])
        #expect(inventory.firmware.first?.isActive == true)
        #expect(inventory.battery == BatteryReading(percentage: 85, chargingStatusCode: 0, source: .unifiedBattery))
    }

    @Test("names longer than one report are read in 16-byte chunks")
    func longName() async throws {
        var device = FakeHIDPPDevice()
        device.name = "Wireless Mobile Mouse MX Anywhere 2S"
        let channel = await channel(device)
        let index = try #require(
            try await RootFeature.location(of: .deviceName, via: channel, device: .direct, timeout: nil)
        )

        #expect(try await DeviceNameFeature.name(via: channel, index: index.index, deviceIndex: .direct) == device.name)
    }

    @Test("absent features produce empty fields instead of errors")
    func absentFeatures() async throws {
        var device = FakeHIDPPDevice()
        device.features = [0x0000, 0x0005]
        let inventory = try await DeviceInventoryReader.read(via: await channel(device), deviceIndex: .direct)

        #expect(inventory.name == "MX Master 3S")
        #expect(inventory.features.isEmpty)
        #expect(inventory.information == nil)
        #expect(inventory.firmware.isEmpty)
        #expect(inventory.battery == nil)
    }

    @Test("an out-of-range battery percentage is reported as unknown")
    func invalidBattery() async throws {
        var device = FakeHIDPPDevice()
        device.batteryStatus = [0x65, 0x00, 0x01, 0x00]
        let inventory = try await DeviceInventoryReader.read(via: await channel(device), deviceIndex: .direct)
        #expect(inventory.battery?.percentage == nil)
        #expect(inventory.battery?.chargingStatusCode == 1)
    }

    @Test("a wrong ping echo is rejected")
    func pingMismatch() async {
        let transport = FakeHIDPPTransport { sent in [HIDPPTestTraffic.reply(to: sent, parameters: [4, 5, 0x00])] }
        let channel = HIDPPChannel(transport: transport, clock: ManualClock())
        await channel.start()
        await #expect(throws: HIDPPRequestError.deviceError(.unknown)) {
            try await RootFeature.protocolVersion(via: channel, device: .direct, timeout: nil)
        }
    }

    @Test("BCD firmware fields decode", arguments: [(UInt8(0x22), 22), (0x09, 9), (0x99, 99), (0x00, 0)])
    func bcd(byte: UInt8, value: Int) {
        #expect(DeviceInformationFeature.bcd(byte) == value)
    }
}

@Suite("ReadOnlyTransportGuard", .timeLimit(.minutes(1)))
struct ReadOnlyTransportGuardTests {
    private typealias Traffic = HIDPPTestTraffic

    private func guarded(
        _ device: FakeHIDPPDevice = FakeHIDPPDevice()
    ) async
        -> (HIDPPChannel<ManualClock>, ReadOnlyTransportGuard, FakeHIDPPTransport)
    {
        let inner = FakeHIDPPTransport(framing: .receiver, responder: device.responder)
        let guardTransport = ReadOnlyTransportGuard(wrapping: inner)
        let channel = HIDPPChannel(transport: guardTransport, clock: ManualClock())
        await channel.start()
        return (channel, guardTransport, inner)
    }

    private static func request(
        _ device: UInt8 = 0xFF,
        feature: UInt8,
        function: UInt8,
        _ parameters: [UInt8] = []
    )
        throws -> HIDPPRequest
    {
        try HIDPPRequest(
            deviceIndex: DeviceIndex(rawValue: device),
            featureIndex: FeatureIndex(rawValue: feature),
            function: try #require(FunctionID(rawValue: function)),
            parameters: parameters,
            kind: .read
        )
    }

    @Test("the complete read-only inventory passes the guard")
    func inventoryPasses() async throws {
        let (channel, guardTransport, _) = await guarded()
        _ = try await DeviceInventoryReader.read(via: channel, deviceIndex: .direct)
        #expect(guardTransport.refusedReports == 0)
    }

    @Test("an unmapped feature index is refused before reaching the device")
    func unmappedIndex() async throws {
        let (channel, guardTransport, inner) = await guarded()
        await #expect(throws: HIDPPRequestError.transport(.blockedByPolicy)) {
            try await channel.send(Self.request(feature: 0x02, function: 0), timeout: .seconds(1))
        }
        #expect(inner.sent.isEmpty)
        #expect(guardTransport.refusedReports == 1)
    }

    @Test("a divert command is refused even after its feature index was looked up")
    func divertRefused() async throws {
        let (channel, _, inner) = await guarded()
        let reprog = try #require(
            try await RootFeature.location(of: .reprogControlsV4, via: channel, device: .direct, timeout: nil)
        )
        let sentBefore = inner.sent.count

        await #expect(throws: HIDPPRequestError.transport(.blockedByPolicy)) {
            try await channel.send(
                Self.request(feature: reprog.index.rawValue, function: 3, [0x00, 0xC3, 0x33]),
                timeout: .seconds(1)
            )
        }
        #expect(inner.sent.count == sentBefore)
    }

    @Test("functions outside the allow-list of an allowed feature are refused (serial number)")
    func serialNumberRefused() async throws {
        let (channel, _, _) = await guarded()
        let info = try #require(
            try await RootFeature.location(of: .deviceInformation, via: channel, device: .direct, timeout: nil)
        )

        await #expect(throws: HIDPPRequestError.transport(.blockedByPolicy)) {
            try await channel.send(Self.request(feature: info.index.rawValue, function: 2), timeout: .seconds(1))
        }
    }

    @Test("a mapping learned for one device does not authorize another")
    func perDeviceMapping() async throws {
        var slot1 = FakeHIDPPDevice()
        slot1.deviceIndex = 1
        let (channel, _, _) = await guarded(slot1)
        let name = try #require(
            try await RootFeature.location(
                of: .deviceName,
                via: channel,
                device: DeviceIndex(rawValue: 1),
                timeout: nil
            )
        )

        await #expect(throws: HIDPPRequestError.transport(.blockedByPolicy)) {
            try await channel.send(Self.request(2, feature: name.index.rawValue, function: 0), timeout: .seconds(1))
        }
    }

    @Test("HID++ 1.0 register access and malformed reports are refused")
    func legacyAndMalformedRefused() async {
        let inner = FakeHIDPPTransport(framing: .receiver)
        let guardTransport = ReadOnlyTransportGuard(wrapping: inner)

        await #expect(throws: HIDPPTransportError.blockedByPolicy) {
            try await guardTransport.send([0x10, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x00])
        }
        await #expect(throws: HIDPPTransportError.blockedByPolicy) { try await guardTransport.send([0x11, 0xFF]) }
        await #expect(throws: HIDPPTransportError.blockedByPolicy) {
            try await guardTransport.send(Traffic.notification(feature: 0x00, function: 0))
        }
        #expect(inner.sent.isEmpty)
    }

    @Test("a policy refusal is not recoverable")
    func refusalNotRecoverable() {
        #expect(!HIDPPTransportError.blockedByPolicy.isRecoverable)
    }
}
