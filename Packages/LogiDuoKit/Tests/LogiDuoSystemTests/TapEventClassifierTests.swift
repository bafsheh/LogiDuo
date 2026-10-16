import LogiDuoDomain
import LogiDuoSystem
import Testing

@Suite("TapEventClassifier")
struct TapEventClassifierTests {
    @Test(
        "buttons 2, 3 and 4 map to middle, back and forward",
        arguments: [
            (Int64(2), MouseButton.middle), (3, .back), (4, .forward),
        ]
    )
    func buttons(number: Int64, button: MouseButton) {
        #expect(
            TapEventClassifier.classify(TapEventSnapshot(kind: .otherMouseDown, buttonNumber: number))
                == .input(.buttonDown(button))
        )
        #expect(
            TapEventClassifier.classify(TapEventSnapshot(kind: .otherMouseUp, buttonNumber: number))
                == .input(.buttonUp(button))
        )
    }

    @Test("other button numbers, including primary and secondary, are ignored", arguments: [Int64(0), 1, 5, 9, 31])
    func ignoredButtons(number: Int64) {
        #expect(TapEventClassifier.classify(TapEventSnapshot(kind: .otherMouseDown, buttonNumber: number)) == .ignore)
        #expect(TapEventClassifier.classify(TapEventSnapshot(kind: .other, buttonNumber: number)) == .ignore)
    }

    @Test("LogiDuo's own synthetic events are never interpreted")
    func syntheticIgnored() {
        let synthetic = TapEventSnapshot(kind: .otherMouseDown, buttonNumber: 3, userData: SyntheticEventMarker.value)
        #expect(TapEventClassifier.classify(synthetic) == .ignore)
    }

    @Test("pointer motion becomes event-tap motion; zero motion is ignored")
    func motion() {
        #expect(
            TapEventClassifier.classify(TapEventSnapshot(kind: .otherMouseDragged, deltaX: -3, deltaY: 4))
                == .input(.motion(dx: -3, dy: 4, source: .eventTap))
        )
        #expect(TapEventClassifier.classify(TapEventSnapshot(kind: .mouseMoved)) == .ignore)
    }

    @Test("horizontal scrolling: positive is right, negative is left")
    func horizontalScroll() {
        #expect(
            TapEventClassifier.classify(TapEventSnapshot(kind: .scrollWheel, horizontalScroll: 1.5))
                == .input(.horizontalScroll(.right, delta: 1.5))
        )
        #expect(
            TapEventClassifier.classify(TapEventSnapshot(kind: .scrollWheel, horizontalScroll: -0.25))
                == .input(.horizontalScroll(.left, delta: -0.25))
        )
    }

    @Test(
        "trackpad, Magic Mouse, momentum and vertical-only scrolling are ignored",
        arguments: [
            TapEventSnapshot(kind: .scrollWheel, horizontalScroll: 2, scrollPhase: 1),
            TapEventSnapshot(kind: .scrollWheel, horizontalScroll: 2, momentumPhase: 3),
            TapEventSnapshot(kind: .scrollWheel, horizontalScroll: 0),
        ]
    )
    func ignoredScrolling(snapshot: TapEventSnapshot) {
        #expect(TapEventClassifier.classify(snapshot) == .ignore)
    }

    @Test("tap disable notifications become supervisor signals, even if marked")
    func signals() {
        #expect(
            TapEventClassifier.classify(TapEventSnapshot(kind: .tapDisabledByTimeout)) == .signal(.disabledByTimeout)
        )
        #expect(
            TapEventClassifier.classify(
                TapEventSnapshot(kind: .tapDisabledByUserInput, userData: SyntheticEventMarker.value)
            )
                == .signal(.disabledByUserInput)
        )
    }
}
