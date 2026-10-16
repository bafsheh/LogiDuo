import LogiDuoDomain
import LogiDuoHIDPP
import LogiDuoTestSupport
import Testing

@Suite("HIDPPChannel correlation", .timeLimit(.minutes(1)))
struct HIDPPChannelTests {
    private typealias Traffic = HIDPPTestTraffic

    private static func request(
        _ device: DeviceIndex = .direct,
        feature: UInt8 = 0x00,
        function: UInt8 = 0,
        _ parameters: [UInt8] = []
    ) -> HIDPPRequest {
        guard
            let function = FunctionID(rawValue: function),
            let request = try? HIDPPRequest(
                deviceIndex: device,
                featureIndex: FeatureIndex(rawValue: feature),
                function: function,
                parameters: parameters,
                kind: .read
            )
        else { preconditionFailure("valid request") }
        return request
    }

    private static let slot1 = DeviceIndex(rawValue: 1)
    private static let slot2 = DeviceIndex(rawValue: 2)

    private func makeChannel(
        framing: HIDPPFraming = .bluetoothLowEnergy,
        responder: FakeHIDPPTransport.Responder? = nil
    ) async -> (HIDPPChannel<ManualClock>, FakeHIDPPTransport, ManualClock) {
        let transport = FakeHIDPPTransport(framing: framing, responder: responder)
        let clock = ManualClock()
        let channel = HIDPPChannel(transport: transport, clock: clock)
        await channel.start()
        return (channel, transport, clock)
    }

    @Test("a matching reply completes the request")
    func matchingReply() async throws {
        let (channel, transport, _) = await makeChannel { sent in
            [Traffic.reply(to: sent, parameters: [0x09, 0x00, 0x04])]
        }

        let reply = try await channel.send(
            Self.request(feature: 0x00, function: 0, [0x1B, 0x04, 0x00]),
            timeout: .seconds(2)
        )

        #expect(Array(reply.parameters.prefix(3)) == [0x09, 0x00, 0x04])
        #expect(transport.sent == [hexBytes("11 FF 00 01 1B 04 00 …")])
    }

    @Test("software identifiers rotate through 1...15 per device index")
    func softwareIDRotation() async throws {
        let (channel, transport, _) = await makeChannel { sent in [Traffic.reply(to: sent)] }

        for _ in 0..<16 {
            _ = try await channel.send(Self.request(), timeout: .seconds(1))
        }
        _ = try await channel.send(Self.request(Self.slot1), timeout: .seconds(1))

        let identifiers = transport.sent.map { $0[3] & 0x0F }
        #expect(identifiers == Array(1...15) + [1, 1])
    }

    @Test(
        "replies from another device index are never attributed",
        arguments: [
            UInt8(0x02), 0xFF, 0x00,
        ]
    )
    func wrongDeviceIndex(otherIndex: UInt8) async throws {
        let (channel, transport, _) = await makeChannel(framing: .receiver)
        let task = Task { try await channel.send(Self.request(Self.slot1), timeout: .seconds(2)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let sent = try #require(await sentReports.next())

        var foreign = Traffic.reply(to: sent, parameters: [0xEE])
        foreign[1] = otherIndex
        transport.deliver(foreign)
        transport.deliver(Traffic.reply(to: sent, parameters: [0x01]))

        #expect(try await task.value.parameters[0] == 0x01)
        #expect(await channel.statistics.unmatchedReplies == 1)
    }

    @Test("a reply with the wrong software identifier or function is not attributed")
    func wrongSoftwareIDOrFunction() async throws {
        let (channel, transport, _) = await makeChannel()
        let task = Task { try await channel.send(Self.request(feature: 0x00, function: 0), timeout: .seconds(2)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let sent = try #require(await sentReports.next())

        var otherSoftware = Traffic.reply(to: sent, parameters: [0xEE])
        otherSoftware[3] = 0x0A
        var nextFunction = Traffic.reply(to: sent, parameters: [0xEE])
        nextFunction[3] = 0x10 | (sent[3] & 0x0F)
        transport.deliver(otherSoftware)
        transport.deliver(nextFunction)
        transport.deliver(Traffic.reply(to: sent, parameters: [0x01]))

        #expect(try await task.value.parameters[0] == 0x01)
        #expect(await channel.statistics.unmatchedReplies == 2)
    }

    @Test("a HID++ 2.0 error is attributed only to the request it echoes")
    func featureErrorAttribution() async throws {
        let (channel, transport, _) = await makeChannel()
        let task = Task { try await channel.send(Self.request(feature: 0x05, function: 1), timeout: .seconds(2)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let sent = try #require(await sentReports.next())

        var otherFeature = sent
        otherFeature[2] = 0x06
        transport.deliver(Traffic.featureError(for: otherFeature, code: 0x02))
        transport.deliver(Traffic.featureError(for: sent, code: 0x09))

        await #expect(throws: HIDPPRequestError.deviceError(.unsupported)) { try await task.value }
        #expect(await channel.statistics.unmatchedReplies == 1)
    }

    @Test("a HID++ 1.0 error (0x8F) from a receiver fails only the addressed slot's request")
    func legacyErrorAttribution() async throws {
        let (channel, transport, _) = await makeChannel(framing: .receiver)
        let first = Task { try await channel.send(Self.request(Self.slot1), timeout: .seconds(2)) }
        let second = Task { try await channel.send(Self.request(Self.slot2), timeout: .seconds(2)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let reports = [try #require(await sentReports.next()), try #require(await sentReports.next())]
        let toSlot1 = try #require(reports.first { $0[1] == 1 })
        let toSlot2 = try #require(reports.first { $0[1] == 2 })

        transport.deliver(Traffic.legacyError(for: toSlot2, code: 0x08))
        transport.deliver(Traffic.reply(to: toSlot1, parameters: [0x42]))

        await #expect(throws: HIDPPRequestError.receiverError(.unknownDevice)) { try await second.value }
        #expect(try await first.value.parameters[0] == 0x42)
    }

    @Test("notifications during a request go to the notification stream")
    func notificationsDuringRequest() async throws {
        let (channel, transport, _) = await makeChannel()
        let task = Task { try await channel.send(Self.request(feature: 0x09, function: 2), timeout: .seconds(2)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let sent = try #require(await sentReports.next())
        var notifications = channel.notifications.makeAsyncIterator()

        let buttons = Traffic.notification(feature: 0x09, function: 0, parameters: [0x00, 0xC3])
        transport.deliver(buttons)
        transport.deliver(Traffic.reply(to: sent))

        _ = try await task.value
        guard case .message(let message) = await notifications.next() else {
            Issue.record("expected a notification")
            return
        }
        #expect(message.featureIndex.rawValue == 0x09 && message.parameters[1] == 0xC3)
        #expect(await channel.statistics.unmatchedReplies == 0)
    }

    @Test("a duplicate reply is dropped")
    func duplicateReply() async throws {
        let (channel, _, _) = await makeChannel { sent in
            [Traffic.reply(to: sent, parameters: [1]), Traffic.reply(to: sent, parameters: [2])]
        }

        let reply = try await channel.send(Self.request(), timeout: .seconds(1))
        _ = try await channel.send(Self.request(), timeout: .seconds(1))

        #expect(reply.parameters[0] == 1)
        #expect(await eventually { await channel.statistics.unmatchedReplies == 2 })
    }

    @Test("requests to one device index are sent one at a time in order")
    func serializationPerDevice() async throws {
        let (channel, transport, _) = await makeChannel()
        let first = Task { try await channel.send(Self.request(feature: 0x01), timeout: .seconds(2)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let firstSent = try #require(await sentReports.next())
        let second = Task { try await channel.send(Self.request(feature: 0x02), timeout: .seconds(2)) }
        #expect(await eventually { await channel.queueDepth(for: .direct) == 1 })
        #expect(transport.sent.count == 1)

        transport.deliver(Traffic.reply(to: firstSent, parameters: [0xA1]))
        let secondSent = try #require(await sentReports.next())
        transport.deliver(Traffic.reply(to: secondSent, parameters: [0xA2]))

        #expect(try await first.value.parameters[0] == 0xA1)
        #expect(try await second.value.parameters[0] == 0xA2)
        #expect(secondSent[2] == 0x02)
    }

    @Test("requests to different receiver slots run concurrently and complete independently")
    func concurrentSlots() async throws {
        let (channel, transport, _) = await makeChannel(framing: .receiver)
        let first = Task { try await channel.send(Self.request(Self.slot1, feature: 0x03), timeout: .seconds(2)) }
        let second = Task { try await channel.send(Self.request(Self.slot2, feature: 0x03), timeout: .seconds(2)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let reports = [try #require(await sentReports.next()), try #require(await sentReports.next())]

        for sent in reports.reversed() {
            transport.deliver(Traffic.reply(to: sent, parameters: [sent[1]]))
        }

        #expect(try await first.value.parameters[0] == 1)
        #expect(try await second.value.parameters[0] == 2)
    }

    @Test("many concurrent callers on several slots all receive their own replies")
    func concurrentCallers() async throws {
        let (channel, _, _) = await makeChannel(framing: .receiver) { sent in
            [Traffic.reply(to: sent, parameters: [sent[1], sent[2]])]
        }

        let results = try await withThrowingTaskGroup(of: (UInt8, UInt8, [UInt8]).self) { group in
            for slot in UInt8(1)...6 {
                for feature in UInt8(1)...8 {
                    group.addTask {
                        let reply = try await channel.send(
                            Self.request(DeviceIndex(rawValue: slot), feature: feature),
                            timeout: .seconds(2)
                        )
                        return (slot, feature, Array(reply.parameters.prefix(2)))
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 48)
        #expect(results.allSatisfy { $0.2 == [$0.0, $0.1] })
    }

    @Test("HID++ 1.0 register traffic is forwarded as a legacy notification")
    func legacyTraffic() async {
        let (channel, transport, _) = await makeChannel(framing: .receiver)
        var notifications = channel.notifications.makeAsyncIterator()

        transport.deliver([0x10, 0xFF, 0x81, 0x02, 0x00, 0x01, 0x00])

        guard case .legacy(let report) = await notifications.next() else {
            Issue.record("expected legacy traffic")
            return
        }
        #expect(report.subID == 0x81)
    }

    @Test("malformed input is counted and ignored")
    func malformedInput() async throws {
        let (channel, transport, _) = await makeChannel { sent in [Traffic.reply(to: sent)] }

        transport.deliver([0x11, 0xFF])
        transport.deliver([0x42] + Array(repeating: 0, count: 19))
        transport.deliver([])
        _ = try await channel.send(Self.request(), timeout: .seconds(1))

        #expect(await channel.statistics.malformedReports == 3)
    }

    @Test("a request the transport cannot frame fails without being sent")
    func unsupportedOutputType() async throws {
        let (channel, transport, _) = await makeChannel(
            framing: HIDPPFraming(outputTypes: [.short], inputIncludesReportID: true)
        )

        await #expect(throws: HIDPPRequestError.framing(.unsupportedOutputType(.long))) {
            try await channel.send(Self.request(), timeout: .seconds(1))
        }
        #expect(transport.sent.isEmpty)
    }
}
