import CoreGraphics
import LogiDuoDomain
import Testing

@Suite("Physical evidence classification")
struct PhysicalEvidenceTests {
    @Test(
        "only unmarked events without a posting process count as physical",
        arguments: [
            (Int64(0), Int64(0), PressOrigin.physical),
            (0, 4242, .otherSynthetic),
            (testInjectionMarker, 0, .otherSynthetic),
            (testInjectionMarker, 4242, .otherSynthetic),
            (SyntheticEventMarker.value, 4242, .logiDuo),
            (SyntheticEventMarker.value, 0, .logiDuo),
        ]
    )
    func origin(userData: Int64, process: Int64, expected: PressOrigin) {
        #expect(PressOrigin.of(userData: userData, sourceProcess: process) == expected)
    }

    @Test("counts are kept per stage, origin and button and printed for scripts")
    func counts() {
        var evidence = PressEvidence()
        evidence.record(stage: .pressed, button: 3, userData: 0, sourceProcess: 0)
        evidence.record(stage: .pressed, button: 3, userData: 0, sourceProcess: 0)
        evidence.record(stage: .delivered, button: 2, userData: SyntheticEventMarker.value, sourceProcess: 77)

        #expect(evidence.count(.pressed, .physical, button: 3) == 2)
        #expect(evidence.count(.delivered, .physical, button: 3) == 0)
        #expect(
            evidence.lines == [
                "[evidence] stage=pressed origin=physical button=3 count=2",
                "[evidence] stage=delivered origin=logiDuo button=2 count=1",
            ]
        )
        #expect(evidence.sourceProcesses == [0, 77])
    }

    @Test("the observer's taps are listen-only: they can never change or suppress input")
    func listenOnly() {
        let pressed = TailTap(listenOnly: true, location: .cghidEventTap, place: .headInsertEventTap)
        let delivered = TailTap(listenOnly: true)
        #expect(pressed.options == .listenOnly && pressed.location == .cghidEventTap)
        #expect(delivered.options == .listenOnly && delivered.location == .cgAnnotatedSessionEventTap)
        #expect(TailTap().options == .defaultTap)
    }
}
