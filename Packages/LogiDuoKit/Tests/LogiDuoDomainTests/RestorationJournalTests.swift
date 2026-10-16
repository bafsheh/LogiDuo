import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("RestorationJournal")
struct RestorationJournalTests {
    private let mouse = DeviceID.fixture(1)
    private let keyboard = DeviceID.fixture(2)

    @Test("a recorded change stays pending until it is restored")
    func pendingUntilRestored() {
        var journal = RestorationJournal()
        journal.willApply(.buttonDiversion(.gesture), on: mouse, original: .notDiverted)

        #expect(!journal.isClean)
        #expect(journal.devicesNeedingRestoration == [mouse])
        journal.restored(.buttonDiversion(.gesture), on: mouse)
        #expect(journal.isClean)
    }

    @Test("regression: repeated changes keep the device's original value")
    func keepsFirstOriginal() {
        var journal = RestorationJournal()
        journal.willApply(.wheelMode, on: mouse, original: .byte(0x02))
        journal.willApply(.wheelMode, on: mouse, original: .byte(0x06))

        let pending = journal.pending(for: mouse)
        #expect(pending.count == 1)
        #expect(pending.first?.setting == .wheelMode && pending.first?.original == .byte(0x02))
    }

    @Test("entries are per device and ordered with diversions first")
    func perDeviceOrdering() {
        var journal = RestorationJournal()
        journal.willApply(.resolution, on: mouse, original: .resolution(1600))
        journal.willApply(.buttonDiversion(.modeShift), on: mouse, original: .notDiverted)
        journal.willApply(.wheelMode, on: mouse, original: .byte(0))
        journal.willApply(.buttonDiversion(.gesture), on: mouse, original: .notDiverted)
        journal.willApply(.smartShift, on: keyboard, original: .bytes([0x02, 0x1E]))

        #expect(
            journal.pending(for: mouse).map(\.setting) == [
                .buttonDiversion(.gesture), .buttonDiversion(.modeShift), .wheelMode, .resolution,
            ]
        )
        #expect(journal.pending(for: keyboard).count == 1)
    }

    @Test("restoring something never recorded is harmless")
    func unknownRestore() {
        var journal = RestorationJournal()
        journal.restored(.smartShift, on: mouse)
        #expect(journal.isClean)
    }

    @Test("the journal round-trips through JSON for persistence")
    func codable() throws {
        var journal = RestorationJournal()
        journal.willApply(.buttonDiversion(.thumb), on: mouse, original: .notDiverted)
        journal.willApply(.smartShift, on: mouse, original: .bytes([0x02, 0x1E]))

        let data = try JSONEncoder().encode(journal)
        let decoded = try JSONDecoder().decode(RestorationJournal.self, from: data)

        #expect(decoded == journal)
        #expect(decoded.pending(for: mouse).count == 2)
    }
}
