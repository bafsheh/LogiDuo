import LogiDuoDomain
import LogiDuoHIDPP
import LogiDuoTestSupport
import Testing

@Suite("HIDPPConnection loss, teardown and power events", .timeLimit(.minutes(1)))
struct HIDPPConnectionLifecycleTests {
    private typealias Traffic = HIDPPTestTraffic
    private typealias Connection = HIDPPConnection<ManualClock>

    private static func configuration(maxFailures: Int = 3) -> HIDPPConnectionConfiguration {
        guard let policy = RetryPolicy(maxConsecutiveFailures: maxFailures) else { preconditionFailure("valid") }
        return HIDPPConnectionConfiguration(retryPolicy: policy)
    }

    private func makeConnection(
        _ factory: FakeTransportFactory,
        maxFailures: Int = 3
    ) -> (Connection, ManualClock) {
        let clock = ManualClock()
        let connection = Connection(
            deviceIndex: .direct,
            configuration: Self.configuration(maxFailures: maxFailures),
            clock: clock,
            openTransport: { () throws(HIDPPTransportError) -> any HIDPPTransport in try factory.open() },
            handshake: { channel, device, timeout throws(HIDPPRequestError) in
                try await RootFeature.handshake(channel, device, timeout)
            }
        )
        return (connection, clock)
    }

    private static func request(_ kind: HIDPPRequestKind, feature: UInt8 = 0x02) -> HIDPPRequest {
        guard
            let function = FunctionID(rawValue: 1),
            let request = try? HIDPPRequest(
                deviceIndex: .direct,
                featureIndex: FeatureIndex(rawValue: feature),
                function: function,
                kind: kind
            )
        else { preconditionFailure("valid request") }
        return request
    }

    /// Answers the handshake, then whatever `afterHandshake` says.
    private static func rootThen(
        _ afterHandshake: @escaping FakeHIDPPTransport.Responder
    ) -> FakeHIDPPTransport.Responder {
        { sent in sent[2] == 0x00 ? FakeTransportFactory.rootResponder(sent) : afterHandshake(sent) }
    }

    @Test("a transport that disconnects while connected is reconnected")
    func transportLoss() async {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)
        await connection.connect()

        factory.transports.first?.disconnect()
        #expect(await eventually { await connection.state == .recovering(cause: .unresponsive, failedAttempts: 0) })
        clock.advance(by: .milliseconds(1500))

        #expect(await eventually { await connection.state == .connected })
        #expect(factory.transports.count == 2)
    }

    @Test("callbacks from an old transport never affect the new session")
    func staleCallbacksIgnored() async throws {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)
        await connection.connect()
        let old = try #require(factory.transports.first)
        old.disconnect()
        #expect(await eventually { await connection.state != .connected })
        clock.advance(by: .milliseconds(1500))
        #expect(await eventually { await connection.state == .connected })
        let current = try #require(factory.transports.last)
        var notifications = connection.notifications.makeAsyncIterator()

        old.deliver(Traffic.notification(feature: 0x04, function: 0, parameters: [0x01]))
        current.deliver(Traffic.notification(feature: 0x04, function: 0, parameters: [0x02]))

        guard case .message(let message) = await notifications.next() else {
            Issue.record("expected a notification")
            return
        }
        #expect(message.parameters[0] == 0x02)
        #expect(await connection.state == .connected)
    }

    @Test("disconnecting closes the transport, fails pending requests and stops reconnects")
    func disconnect() async throws {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)
        await connection.connect()
        let transport = try #require(factory.transports.first)
        transport.setResponder(Self.rootThen { _ in [] })
        let pending = Task { try await connection.perform(Self.request(.read)) }
        #expect(await eventually { transport.sent.count == 2 })

        await connection.disconnect()

        await #expect(throws: HIDPPRequestError.channelClosed) { try await pending.value }
        #expect(await connection.state == .disconnected(.requested))
        #expect(transport.closeCalls == 1)
        clock.advance(by: .seconds(60))
        for _ in 0..<100 { await Task.yield() }
        #expect(factory.openAttempts == 1)
        await #expect(throws: HIDPPRequestError.notConnected) { try await connection.perform(Self.request(.read)) }
    }

    @Test("disconnecting during a connection attempt abandons the attempt and closes its transport")
    func disconnectDuringConnect() async {
        let factory = FakeTransportFactory(fallback: .open(nil))
        let (connection, _) = makeConnection(factory)
        let connecting = Task { await connection.connect() }
        #expect(await eventually { factory.transports.first?.sent.count == 1 })

        await connection.disconnect()
        await connecting.value

        #expect(await connection.state == .disconnected(.requested))
        #expect(factory.transports.first?.closeCalls ?? 0 >= 1)
        #expect(await connection.rejectedEvents == 0)
    }

    @Test("a removed device is not reconnected")
    func removal() async {
        let factory = FakeTransportFactory([.fail(.disconnected)], fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)
        await connection.connect()

        await connection.deviceRemoved()
        clock.advance(by: .seconds(60))
        for _ in 0..<100 { await Task.yield() }

        #expect(await connection.state == .disconnected(.removed))
        #expect(factory.openAttempts == 1)

        await connection.deviceRediscovered()
        await connection.connect()
        #expect(await connection.state == .connected)
    }

    @Test("sleep closes the link and suspends reconnects until wake")
    func sleepWake() async {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)
        await connection.connect()

        await connection.hostWillSleep()
        #expect(await connection.state == .suspended)
        #expect(factory.transports.first?.closeCalls == 1)
        clock.advance(by: .seconds(3600))
        for _ in 0..<100 { await Task.yield() }
        #expect(factory.openAttempts == 1)

        await connection.hostDidWake()
        #expect(await connection.state == .recovering(cause: .hostWoke, failedAttempts: 0))
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { await connection.state == .connected })
        #expect(factory.openAttempts == 2)
        #expect(await connection.rejectedEvents == 0)
    }

    @Test("repeated connect and disconnect cycles close every transport exactly once")
    func repeatedCycles() async {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, _) = makeConnection(factory)

        for _ in 0..<20 {
            await connection.connect()
            #expect(await connection.state == .connected)
            await connection.disconnect()
        }

        #expect(factory.transports.count == 20)
        #expect(factory.transports.allSatisfy { $0.closeCalls == 1 })
        #expect(await connection.openedTransports == 20)
        #expect(await connection.rejectedEvents == 0)
    }

    @Test("backoff doubles up to the maximum")
    func backoff() {
        let policy = BackoffPolicy.standard
        let delays = (0...7).map { policy.delay(afterFailures: $0) }
        #expect(
            delays == [
                .milliseconds(1500), .milliseconds(1500), .seconds(3), .seconds(6), .seconds(12), .seconds(24),
                .seconds(30), .seconds(30),
            ]
        )
    }
}
