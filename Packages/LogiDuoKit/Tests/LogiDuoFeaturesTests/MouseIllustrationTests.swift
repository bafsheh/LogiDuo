import LogiDuoDomain
import Testing

@testable import LogiDuoFeatures

@Suite("MouseIllustrationLayout")
struct MouseIllustrationTests {
    @Test("MX Master fixture covers every editable button and the thumb wheel")
    func mxMasterCoverage() {
        let triggers = MouseIllustrationLayout.mxMaster.hotspots.flatMap(\.triggers)
        let expected: [InputTrigger] =
            [.press(.middle), .press(.back), .press(.forward), .press(.gesture), .press(.modeShift)]
            + HorizontalScrollDirection.allCases.map(InputTrigger.horizontalScroll)
        #expect(Set(triggers) == Set(expected))
        #expect(triggers.count == Set(triggers).count)
        #expect(MouseIllustrationLayout.mxMaster.silhouette == .ergonomic)
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

    @Test("a mouse with only a middle button gets a compact silhouette and one spot")
    func compactMiddleOnly() {
        let layout = MouseIllustrationLayout.make(buttons: [.middle, .primary], hasThumbwheel: false)
        #expect(layout.silhouette == .compact)
        #expect(layout.hotspots.map(\.id) == ["middle"])
        #expect(!layout.hasSideRail)
    }

    @Test("side buttons and thumbwheel produce an ergonomic silhouette with a left rail")
    func ergonomicFromSideControls() {
        let layout = MouseIllustrationLayout.make(
            buttons: [.middle, .back, .forward],
            hasThumbwheel: true
        )
        #expect(layout.silhouette == .ergonomic)
        #expect(layout.hasSideRail)
        let ids = Set(layout.hotspots.map(\.id))
        #expect(ids == ["middle", "back", "forward", "thumbwheel"])
    }

    @Test("extra buttons appear only when requested and stay spaced apart")
    func scalesWithExtraButtons() {
        let layout = MouseIllustrationLayout.make(
            buttons: [.middle, .back, .forward, .gesture, .thumb, .dpiSwitch, .sensePanel],
            hasThumbwheel: false
        )
        #expect(layout.hotspots.count == 7)
        for (index, spot) in layout.hotspots.enumerated() {
            for other in layout.hotspots[(index + 1)...] {
                let distance = ((spot.x - other.x) * (spot.x - other.x) + (spot.y - other.y) * (spot.y - other.y))
                    .squareRoot()
                #expect(distance > 0.07, "\(spot.id) and \(other.id) overlap")
            }
        }
    }

    @Test("unsupported thumbwheel is omitted when capabilities say so")
    func capabilitiesOmitThumbwheel() {
        let capabilities = MouseCapabilities(
            divertableButtons: .supported([.middle, .back]),
            thumbwheel: .unsupported
        )
        let layout = MouseIllustrationLayout.make(capabilities: capabilities, deviceButtonsAvailable: true)
        #expect(!layout.hotspots.contains { $0.id == "thumbwheel" })
        #expect(layout.hotspots.contains { $0.id == "back" })
    }
}
