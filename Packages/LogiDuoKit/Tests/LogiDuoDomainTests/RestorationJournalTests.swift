import Foundation
import LogiDuoDomain
import Testing

@Suite("RestorationJournal")
struct RestorationJournalTests {
    private let mouse = RestorationDeviceKey(rawValue: "key-mouse")
    private let keyboard = RestorationDeviceKey(rawValue: "key-keyboard")
    private let gesture = RestorableSetting.controlReporting(DeviceControlID(rawValue: 0x00C3))
    private let modeShift = RestorableSetting.controlReporting(DeviceControlID(rawValue: 0x00C4))
    private let native = RestorationValue.controlReporting(diverted: false, rawXYDiverted: false)

    @Test("a recorded change stays pending until its restore is confirmed")
    func pendingUntilRestored() {
        var journal = RestorationJournal()
        journal.willApply(gesture, on: mouse, original: native)

        #expect(!journal.isClean)
        #expect(journal.devicesNeedingRestoration == [mouse])
        journal.restored(gesture, on: mouse)
        #expect(journal.isClean)
    }

    @Test("failed restore attempts are counted and never drop the entry")
    func failedAttempts() {
        var journal = RestorationJournal()
        journal.willApply(gesture, on: mouse, original: native)
        journal.restoreFailed(gesture, on: mouse)
        journal.restoreFailed(gesture, on: mouse)

        #expect(journal.pending(for: mouse).first?.failedAttempts == 2)
        #expect(!journal.isClean)
    }

    @Test("regression: repeated changes keep the device's original value")
    func keepsFirstOriginal() {
        var journal = RestorationJournal()
        journal.willApply(.wheelMode, on: mouse, original: .byte(0x02))
        journal.willApply(.wheelMode, on: mouse, original: .byte(0x06))

        #expect(journal.pending(for: mouse).first?.original == .byte(0x02))
    }

    @Test("entries are per device and ordered with control reporting first")
    func perDeviceOrdering() {
        var journal = RestorationJournal()
        journal.willApply(.resolution, on: mouse, original: .resolution(1600))
        journal.willApply(modeShift, on: mouse, original: native)
        journal.willApply(.wheelMode, on: mouse, original: .byte(0))
        journal.willApply(gesture, on: mouse, original: native)
        journal.willApply(.smartShift, on: keyboard, original: .bytes([0x02, 0x1E]))

        #expect(journal.pending(for: mouse).map(\.setting) == [gesture, modeShift, .wheelMode, .resolution])
        #expect(journal.pending(for: keyboard).count == 1)
        #expect(journal.entries.count == 5)
    }

    @Test("restoring something never recorded is harmless")
    func unknownRestore() {
        var journal = RestorationJournal()
        journal.restored(.smartShift, on: mouse)
        journal.restoreFailed(.smartShift, on: mouse)
        #expect(journal.isClean)
    }

    @Test("the journal round-trips through JSON")
    func codable() throws {
        var journal = RestorationJournal()
        journal.willApply(gesture, on: mouse, original: .controlReporting(diverted: false, rawXYDiverted: false))
        journal.willApply(.smartShift, on: mouse, original: .bytes([0x02, 0x1E]))
        journal.restoreFailed(.smartShift, on: mouse)

        let decoded = try JSONDecoder().decode(RestorationJournal.self, from: try JSONEncoder().encode(journal))

        #expect(decoded == journal)
        #expect(decoded.pending(for: mouse).count == 2)
    }

    @Test("control identifiers print as four hex digits")
    func controlDescription() {
        #expect(DeviceControlID(rawValue: 0xC3).description == "0x00C3")
    }
}
