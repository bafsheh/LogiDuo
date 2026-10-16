import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoHIDPP

@Suite("SingleUseDivertExperiment failure injection (fake device only)", .timeLimit(.minutes(1)))
struct SingleUseDivertFailureTests {
    private typealias Rigs = ControlDivertTransactionTests
    private typealias Harness = SingleUseDivertExperimentTests

    // MARK: Failures after the write may have reached the device

    @Test("an acknowledged divert without a state change is recovered and reported")
    func ackWithoutChange() async {
        let device = FakeReprogDevice()
        device.setFault(.ignoresWrites)
        let rig = await Harness.rig(device: device)
        let report = await rig.harness.run(await rig.token())

        #expect(report.outcome == .divertFailedAndRecovered(.verificationFailed(0x00C3)))
        #expect(rig.writes() == [0x03])
        #expect(rig.store.persisted.isClean)
    }

    @Test("regression: a divert whose reply is lost is assumed applied and is undone")
    func lostReplyIsNotAssumedUnapplied() async {
        let device = FakeReprogDevice()
        device.setFault(.dropsWriteReplies)
        device.onWrite { _ in device.setFault(.none) }
        let rig = await Harness.rig(device: device)

        let report = await rig.harness.run(await rig.token())

        guard case .divertFailedAndRecovered(.request) = report.outcome else {
            Issue.record("expected a recovered timeout, got \(report.outcome)")
            return
        }
        #expect(rig.writes() == [0x03, 0x02])
        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a disconnect after the divert keeps the record; the next connection restores")
    func disconnect() async {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        let rig = await Harness.rig(device: device, store: store)
        let transport = rig.transport
        device.onWrite { _ in transport.disconnect() }

        guard case .recoveryPending = await rig.harness.run(await rig.token()).outcome else {
            Issue.record("restore cannot run on a dead connection")
            return
        }
        #expect(store.persisted.entries.count == 1)
        #expect(device.reportingFlags(of: 0x00C3) == 0x01)

        device.onWrite(nil)
        let reconnected = await Harness.rig(device: device, store: store)
        #expect(await reconnected.recovery.exactRestore().isComplete)
        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(store.persisted.isClean)
    }

    @Test("a device that goes silent after the divert: restore times out, the record is kept")
    func restoreTimeout() async {
        let device = FakeReprogDevice()
        let rig = await Harness.rig(device: device)
        device.onWrite { _ in device.setFault(.unresponsive) }

        guard case .recoveryPending = await rig.harness.run(await rig.token()).outcome else {
            Issue.record("expected recovery pending")
            return
        }
        #expect(rig.writes() == [0x03])
        #expect(device.reportingFlags(of: 0x00C3) == 0x01)
        #expect(rig.store.persisted.entries.count == 1)
    }

    @Test("a restore acknowledged without a state change keeps the record")
    func restoreAckWithoutChange() async {
        let device = FakeReprogDevice()
        let rig = await Harness.rig(device: device)
        device.onWrite { control in
            if device.reportingFlags(of: control) == 0x01 { device.setFault(.ignoresWrites) }
        }

        let report = await rig.harness.run(await rig.token())

        guard case .recoveryPending(let restoration) = report.outcome else {
            Issue.record("expected recovery pending")
            return
        }
        #expect(restoration.failed[Rigs.gestureSetting] == .restorationIncomplete(0x00C3))
        #expect(device.reportingFlags(of: 0x00C3) == 0x01)
        #expect(rig.store.persisted.entries.first?.failedAttempts == 1)
    }

    // MARK: Cancellation, termination, restart, concurrency

    @Test("cancelled before starting: aborted, nothing sent, token spent")
    func cancelledBeforeStart() async {
        let rig = await Harness.rig()
        let token = await rig.token()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await rig.harness.run(token)
        }
        #expect(await task.value.outcome == .aborted(.cancelled))
        #expect(rig.writes().isEmpty)
        #expect(await rig.harness.run(token).outcome == .aborted(.notAuthorized))
    }

    @Test("regression: cancellation right after the divert still restores the device")
    func cancelledAfterDivert() async {
        let device = FakeReprogDevice()
        let rig = await Harness.rig(device: device)
        let token = await rig.token()
        let box = TaskBox()
        device.onWrite { _ in box.cancel() }
        let task = Task { await rig.harness.run(token) }
        box.set(task)

        let report = await task.value

        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(rig.store.persisted.isClean)
        // Whether the cancelled read-back completed or not, restoration must have run.
        switch report.outcome {
        case .completed, .divertFailedAndRecovered: break
        default: Issue.record("restoration must survive cancellation, got \(report.outcome)")
        }
        #expect(rig.writes() == [0x03, 0x02])
    }

    @Test("regression: restoration survives cancellation even when the device answers slowly")
    func cancelledWithSlowDevice() async {
        let device = FakeReprogDevice()
        let rig = await Harness.rig(device: device)
        let transport = rig.transport
        let slow = Flag()
        let box = TaskBox()
        transport.setResponder { sent in
            let replies = device.responder(sent)
            guard slow.isSet else { return replies }
            let latency = ContinuousClock()
            Task {
                try? await latency.sleep(for: .milliseconds(10))
                for reply in replies { transport.deliver(reply) }
            }
            return []
        }
        device.onWrite { _ in
            slow.set()
            box.cancel()
        }
        let token = await rig.token()
        let task = Task { await rig.harness.run(token) }
        box.set(task)

        _ = await task.value

        #expect(device.reportingFlags(of: 0x00C3) == 0)
        #expect(rig.store.persisted.isClean)
    }

    @Test("a forged token reusing a real nonce under another session is refused")
    func forgedSession() async {
        let rig = await Harness.rig()
        let real = await rig.token()
        let forged = ExperimentAuthorization(
            session: real.session &+ 1,
            nonce: real.nonce,
            operation: real.operation,
            expectedUnit: real.expectedUnit
        )
        #expect(await rig.harness.run(forged).outcome == .aborted(.notAuthorized))
        #expect(rig.writes().isEmpty)
    }

    @Test("process termination after the divert: restart refuses a new run until recovery, then works")
    func terminationAndRestart() async throws {
        let device = FakeReprogDevice()
        let store = InMemoryJournalStore()
        // The process dies right after the divert (no restore runs).
        try await ControlDivertTransactionTests.rig(device: device, store: store)
            .transaction.divert(Rigs.gesture, with: .divertButtonOnly)

        let restarted = await Harness.rig(device: device, store: store)
        #expect(await restarted.harness.run(await restarted.token()).outcome == .aborted(.journalNotClean))
        #expect(await restarted.recovery.exactRestore().isComplete)
        #expect(device.reportingFlags(of: 0x00C3) == 0)

        let next = await Harness.rig(device: device, store: store)
        #expect(await next.harness.run(await next.token()).outcome == .completed)
    }

    @Test("a concurrent recovery request never interleaves with the run")
    func concurrentRecovery() async {
        let rig = await Harness.rig()
        let token = await rig.token()
        async let run = rig.harness.run(token)
        async let recovered = rig.recovery.exactRestore()
        let (report, restoration) = await (run, recovered)

        #expect(report.outcome == .completed || report.outcome == .aborted(.journalNotClean))
        #expect(restoration.failed.isEmpty)
        #expect(rig.device.reportingFlags(of: 0x00C3) == 0)
        #expect(rig.store.persisted.isClean)
        #expect(rig.writes().filter { $0 == 0x03 }.count == rig.writes().filter { $0 == 0x02 }.count)
    }

    @Test("unrelated controls are never touched, even when diverted")
    func unrelatedUntouched() async {
        let device = FakeReprogDevice()
        device.setReportingFlags(0x01, of: 0x00C4)
        device.setReportingFlags(0x01, of: 0x0052)
        let rig = await Harness.rig(device: device)

        #expect(await rig.harness.run(await rig.token()).outcome == .completed)
        #expect(device.writeLog.allSatisfy { $0.0 == 0x00C3 })
        #expect(device.reportingFlags(of: 0x00C4) == 0x01 && device.reportingFlags(of: 0x0052) == 0x01)
    }
}
