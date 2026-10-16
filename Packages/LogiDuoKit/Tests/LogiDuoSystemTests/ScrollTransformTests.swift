import LogiDuoDomain
import Testing

@testable import LogiDuoSystem

@Suite("ScrollTransform")
struct ScrollTransformTests {
    private static let down = ScrollAxis(lines: -1, fixed: -1.0, points: -10)

    private static func wheel(
        _ vertical: ScrollAxis = down,
        horizontal: ScrollAxis = .zero,
        shift: Bool = false,
        phase: Int64 = 0
    )
        -> ScrollFields
    {
        ScrollFields(vertical: vertical, horizontal: horizontal, scrollPhase: phase, momentumPhase: 0, shift: shift)
    }

    private static func settings(
        vertical: Bool = false,
        horizontal: Bool = false,
        shift: Bool = false,
        ignoreTrackpad: Bool = true
    ) -> ScrollSettings {
        ScrollSettings(
            invertVertical: vertical,
            invertHorizontal: horizontal,
            ignoreTrackpad: ignoreTrackpad,
            shiftScrollsHorizontally: shift,
            horizontalActionThreshold: 1
        )
    }

    @Test("native settings change nothing")
    func native() {
        #expect(ScrollTransform.apply(.standard, to: Self.wheel()) == nil)
    }

    @Test("vertical inversion flips every unit of the vertical axis only")
    func invertVertical() {
        let result = ScrollTransform.apply(
            Self.settings(vertical: true),
            to: Self.wheel(horizontal: ScrollAxis(lines: 1, fixed: 1, points: 5))
        )
        #expect(result?.vertical == ScrollAxis(lines: 1, fixed: 1, points: 10))
        #expect(result?.horizontal == ScrollAxis(lines: 1, fixed: 1, points: 5))
    }

    @Test("horizontal inversion flips the thumb wheel")
    func invertHorizontal() {
        let result = ScrollTransform.apply(
            Self.settings(horizontal: true),
            to: Self.wheel(.zero, horizontal: ScrollAxis(lines: 2, fixed: 2, points: 20))
        )
        #expect(result?.horizontal == ScrollAxis(lines: -2, fixed: -2, points: -20))
    }

    @Test("trackpad and Magic Mouse scrolling are left alone unless included")
    func trackpad() {
        let gesture = Self.wheel(phase: 2)
        #expect(ScrollTransform.apply(Self.settings(vertical: true), to: gesture) == nil)
        #expect(ScrollTransform.apply(Self.settings(vertical: true, ignoreTrackpad: false), to: gesture) != nil)
    }

    @Test("Shift turns vertical wheel scrolling horizontal, then inversion applies")
    func shiftHorizontal() {
        let result = ScrollTransform.apply(Self.settings(horizontal: true, shift: true), to: Self.wheel(shift: true))
        #expect(result?.vertical == .zero)
        #expect(result?.horizontal == Self.down.inverted)
        #expect(ScrollTransform.apply(Self.settings(shift: true), to: Self.wheel()) == nil)
    }
}
