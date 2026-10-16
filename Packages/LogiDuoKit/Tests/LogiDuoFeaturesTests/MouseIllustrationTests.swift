import LogiDuoDomain
import Testing

@testable import LogiDuoFeatures

@Suite("MouseIllustrationLayout")
struct MouseIllustrationTests {
    @Test("every editable button and the thumb wheel has exactly one spot on the drawing")
    func coverage() {
        let triggers = MouseIllustrationLayout.mxMaster.hotspots.flatMap(\.triggers)
        let expected: [InputTrigger] =
            [.press(.middle), .press(.back), .press(.forward), .press(.gesture), .press(.modeShift)]
            + HorizontalScrollDirection.allCases.map(InputTrigger.horizontalScroll)
        #expect(Set(triggers) == Set(expected))
        #expect(triggers.count == Set(triggers).count)
    }

    @Test("spots lie inside the drawing and never on top of each other")
    func geometry() {
        let spots = MouseIllustrationLayout.mxMaster.hotspots
        #expect(spots.allSatisfy { (0.05...0.95).contains($0.x) && (0.05...0.95).contains($0.y) })
        for (index, spot) in spots.enumerated() {
            for other in spots[(index + 1)...] {
                let distance = ((spot.x - other.x) * (spot.x - other.x) + (spot.y - other.y) * (spot.y - other.y))
                    .squareRoot()
                #expect(distance > 0.07, "\(spot.id) and \(other.id) overlap")
            }
        }
    }

    @Test("protected primary and secondary buttons are not on the drawing")
    func protected() {
        let buttons = MouseIllustrationLayout.mxMaster.hotspots.flatMap(\.triggers).compactMap(\.button)
        #expect(!buttons.contains(.primary) && !buttons.contains(.secondary))
    }
}
