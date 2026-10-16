import LogiDuoDomain
import LogiDuoHIDPP
import LogiDuoTestSupport
import Testing

@Suite("HIDPPChannel timeouts, cancellation and closure")
struct HIDPPChannelLifecycleTests {
    private typealias Traffic = HIDPPTestTraffic

    private static func request(_ device: DeviceIndex = .direct, feature: UInt8 = 0x00) -> HIDPPRequest {
        guard
            let function = FunctionID(rawValue: 0),
            let request = try? HIDPPRequest(
                deviceIndex: device,
                featureIndex: FeatureIndex(rawValue: feature),
                function: function,
                kind: .read
            )
        else { preconditionFailure("valid request") }
        return request
    }

    private func makeChannel() async -> (HIDPPChannel<ManualClock>, FakeHIDPPTransport, ManualClock) {
        let transport = FakeHIDPPTransport()
        let clock = ManualClock()
        let channel = HIDPPChannel(transport: transport, clock: clock)
        await channel.start()
        return (channel, transport, clock)
    }

    @Test("a request times out when the clock passes its deadline, not before")
    func timeout() async throws {
        let (channel, transport, clock) = await makeChannel()
        let task = Task { try await channel.send(Self.request(), timeout: .milliseconds(400)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        _ = try #require(await sentReports.next())

        clock.advance(by: .milliseconds(399))
        #expect(await channel.isAwaitingReply(from: .direct))
        clock.advance(by: .milliseconds(1))

        await #expect(throws: HIDPPRequestError.timeout) { try await task.value }
        #expect(await !channel.isAwaitingReply(from: .direct))
    }

    @Test("regression: a late reply after a timeout cannot complete the next request")
    func lateReplyAfterTimeout() async throws {
        let (channel, transport, clock) = await makeChannel()
        let first = Task { try await channel.send(Self.request(), timeout: .milliseconds(400)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let firstSent = try #require(await sentReports.next())
        clock.advance(by: .milliseconds(400))
        await #expect(throws: HIDPPRequestError.timeout) { try await first.value }

        let second = Task { try await channel.send(Self.request(), timeout: .seconds(2)) }
        let secondSent = try #require(await sentReports.next())
        transport.deliver(Traffic.reply(to: firstSent, parameters: [0xDE]))
        transport.deliver(Traffic.reply(to: secondSent, parameters: [0x02]))

        #expect(try await second.value.parameters[0] == 0x02)
        #expect(firstSent[3] != secondSent[3])
        #expect(await channel.statistics.unmatchedReplies == 1)
    }

    @Test("cancelling the caller ends the wait, and the late reply is dropped")
    func cancellation() async throws {
        let (channel, transport, _) = await makeChannel()
        let task = Task { try await channel.send(Self.request(), timeout: .seconds(10)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let sent = try #require(await sentReports.next())

        task.cancel()
        await #expect(throws: HIDPPRequestError.cancelled) { try await task.value }

        transport.deliver(Traffic.reply(to: sent))
        transport.setResponder { sent in [Traffic.reply(to: sent, parameters: [0x07])] }
        #expect(try await channel.send(Self.request(), timeout: .seconds(1)).parameters[0] == 0x07)
        #expect(await channel.statistics.unmatchedReplies == 1)
    }

    @Test("cancelling a queued request removes it without sending")
    func cancelQueued() async throws {
        let (channel, transport, _) = await makeChannel()
        let first = Task { try await channel.send(Self.request(feature: 1), timeout: .seconds(10)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        let firstSent = try #require(await sentReports.next())
        let queued = Task { try await channel.send(Self.request(feature: 2), timeout: .seconds(10)) }
        #expect(await eventually { await channel.queueDepth(for: .direct) == 1 })

        queued.cancel()
        await #expect(throws: HIDPPRequestError.cancelled) { try await queued.value }
        #expect(await channel.queueDepth(for: .direct) == 0)

        transport.deliver(Traffic.reply(to: firstSent))
        _ = try await first.value
        #expect(transport.sent.count == 1)
    }

    @Test("a disconnect mid-request fails the outstanding and the queued request")
    func disconnectMidRequest() async throws {
        let (channel, transport, _) = await makeChannel()
        let first = Task { try await channel.send(Self.request(feature: 1), timeout: .seconds(10)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        _ = try #require(await sentReports.next())
        let queued = Task { try await channel.send(Self.request(feature: 2), timeout: .seconds(10)) }
        #expect(await eventually { await channel.queueDepth(for: .direct) == 1 })

        transport.disconnect()

        await #expect(throws: HIDPPRequestError.transport(.disconnected)) { try await first.value }
        await #expect(throws: HIDPPRequestError.transport(.disconnected)) { try await queued.value }
        #expect(await channel.isClosed)
        await #expect(throws: HIDPPRequestError.transport(.disconnected)) {
            try await channel.send(Self.request(), timeout: .seconds(1))
        }
    }

    @Test("closing fails pending work, finishes notifications and closes the transport once")
    func close() async throws {
        let (channel, transport, _) = await makeChannel()
        let pending = Task { try await channel.send(Self.request(), timeout: .seconds(10)) }
        var sentReports = transport.sentReports.makeAsyncIterator()
        _ = try #require(await sentReports.next())

        await channel.close()
        await channel.close()

        await #expect(throws: HIDPPRequestError.channelClosed) { try await pending.value }
        var notifications = channel.notifications.makeAsyncIterator()
        #expect(await notifications.next() == nil)
        #expect(transport.closeCalls == 2)
    }

    @Test("a failing send reports the transport error and frees the device index")
    func sendFailure() async throws {
        let (channel, transport, _) = await makeChannel()
        transport.failSends(with: .ioFailure(code: -536_870_212))

        await #expect(throws: HIDPPRequestError.transport(.ioFailure(code: -536_870_212))) {
            try await channel.send(Self.request(), timeout: .seconds(1))
        }

        transport.failSends(with: nil)
        transport.setResponder { sent in [Traffic.reply(to: sent)] }
        _ = try await channel.send(Self.request(), timeout: .seconds(1))
    }

    @Test("a reply delivered while the send is in flight is not lost")
    func replyDuringSend() async throws {
        let (channel, transport, _) = await makeChannel()
        transport.setResponder { sent in [Traffic.reply(to: sent, parameters: [0x5A])] }

        let reply = try await channel.send(Self.request(), timeout: .seconds(1))

        #expect(reply.parameters[0] == 0x5A)
    }

    @Test("request errors classify retryability")
    func transientErrors() {
        #expect(HIDPPRequestError.timeout.isTransient)
        #expect(HIDPPRequestError.deviceError(.busy).isTransient)
        #expect(HIDPPRequestError.receiverError(.busy).isTransient)
        #expect(!HIDPPRequestError.deviceError(.invalidFeatureIndex).isTransient)
        #expect(!HIDPPRequestError.receiverError(.unknownDevice).isTransient)
        #expect(HIDPPRequestError.transport(.disconnected).isTransient)
        #expect(!HIDPPRequestError.transport(.accessDenied).isTransient)
        #expect(!HIDPPRequestError.cancelled.isTransient)
    }
}
