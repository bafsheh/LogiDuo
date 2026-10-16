import LogiDuoDomain
import LogiDuoHIDPP
import LogiDuoTestSupport
import Testing

@Suite("HIDPPConnection lifecycle", .timeLimit(.minutes(1)))
struct HIDPPConnectionTests {
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

    @Test("connecting opens a transport and verifies the device with a read-only ping")
    func connects() async throws {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, _) = makeConnection(factory)

        await connection.connect()

        #expect(await connection.state == .connected)
        #expect(await connection.generation == 1)
        let transport = try #require(factory.transports.first)
        #expect(transport.sent == [hexBytes("11 FF 00 11 00 00 5A …")])
        #expect(await connection.rejectedEvents == 0)
    }

    @Test("a transient open failure is retried after the backoff delay")
    func retriesAfterBackoff() async {
        let factory = FakeTransportFactory(
            [.fail(.ioFailure(code: 1))],
            fallback: .open(FakeTransportFactory.rootResponder)
        )
        let (connection, clock) = makeConnection(factory)

        await connection.connect()
        #expect(await connection.state == .recovering(cause: .attemptFailed(.ioError), failedAttempts: 1))

        clock.advance(by: .milliseconds(1499))
        #expect(factory.openAttempts == 1)
        clock.advance(by: .milliseconds(1))

        #expect(await eventually { await connection.state == .connected })
        #expect(factory.openAttempts == 2)
        #expect(await connection.rejectedEvents == 0)
    }

    @Test("gives up after the retry limit and stops reconnecting")
    func retryLimit() async {
        let factory = FakeTransportFactory(fallback: .fail(.ioFailure(code: 1)))
        let (connection, clock) = makeConnection(factory, maxFailures: 3)

        await connection.connect()
        clock.advance(by: .milliseconds(1500))
        #expect(await eventually { factory.openAttempts == 2 })
        clock.advance(by: .seconds(3))
        #expect(await eventually { await connection.state == .failed(.retriesExhausted) })

        clock.advance(by: .seconds(600))
        for _ in 0..<100 { await Task.yield() }
        #expect(factory.openAttempts == 3)
    }

    @Test("access denied fails permanently without retrying")
    func accessDenied() async {
        let factory = FakeTransportFactory(fallback: .fail(.accessDenied))
        let (connection, clock) = makeConnection(factory)

        await connection.connect()
        clock.advance(by: .seconds(60))
        for _ in 0..<100 { await Task.yield() }

        #expect(await connection.state == .failed(.accessDenied))
        #expect(factory.openAttempts == 1)
    }

    @Test("a silent device times out during the handshake and is retried")
    func handshakeTimeout() async {
        let factory = FakeTransportFactory([.open(nil)], fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)

        let connecting = Task { await connection.connect() }
        #expect(await eventually { factory.transports.first?.sent.count == 1 })
        clock.advance(by: .milliseconds(400))
        await connecting.value

        #expect(await connection.state == .recovering(cause: .attemptFailed(.timeout), failedAttempts: 1))
        #expect(factory.transports.first?.closeCalls == 1)
    }

    @Test("reads are retried once on timeout; writes are never retried")
    func readRetryWriteNoRetry() async throws {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)
        await connection.connect()
        let transport = try #require(factory.transports.first)
        transport.setResponder(Self.rootThen { _ in [] })

        let read = Task { try await connection.perform(Self.request(.read)) }
        #expect(await eventually { transport.sent.count == 2 })
        transport.setResponder(Self.rootThen { sent in [Traffic.reply(to: sent, parameters: [0x77])] })
        clock.advance(by: .seconds(2))
        #expect(try await read.value.parameters[0] == 0x77)
        #expect(transport.sent.count == 3)

        transport.setResponder(Self.rootThen { _ in [] })
        let write = Task { try await connection.perform(Self.request(.write)) }
        #expect(await eventually { transport.sent.count == 4 })
        clock.advance(by: .seconds(2))
        await #expect(throws: HIDPPRequestError.timeout) { try await write.value }
        for _ in 0..<100 { await Task.yield() }
        #expect(transport.sent.count == 4)
    }

    @Test("consecutive timeouts mark the device unresponsive and trigger a reconnect")
    func unresponsiveReconnects() async throws {
        let factory = FakeTransportFactory(fallback: .open(FakeTransportFactory.rootResponder))
        let (connection, clock) = makeConnection(factory)
        await connection.connect()
        let first = try #require(factory.transports.first)
        first.setResponder(Self.rootThen { _ in [] })

        for expectedSends in 2...4 {
            let write = Task { try await connection.perform(Self.request(.write)) }
            #expect(await eventually { first.sent.count == expectedSends })
            clock.advance(by: .seconds(2))
            await #expect(throws: HIDPPRequestError.timeout) { try await write.value }
        }

        #expect(await connection.state == .recovering(cause: .unresponsive, failedAttempts: 0))
        #expect(first.closeCalls == 1)
        await #expect(throws: HIDPPRequestError.notConnected) { try await connection.perform(Self.request(.read)) }
        clock.advance(by: .milliseconds(1500))
        #expect(await eventually { await connection.state == .connected })
        #expect(factory.transports.count == 2)
        #expect(await connection.rejectedEvents == 0)
    }
}
