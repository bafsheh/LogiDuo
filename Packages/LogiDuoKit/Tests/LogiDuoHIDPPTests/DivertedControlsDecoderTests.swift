import LogiDuoDomain
import Testing

@testable import LogiDuoHIDPP

@Suite("DivertedControlsDecoder")
struct DivertedControlsDecoderTests {
    @Test("presses and releases are the difference between pressed sets")
    func pressRelease() {
        var decoder = DivertedControlsDecoder()
        #expect(decoder.decode(function: 0, parameters: [0x00, 0xC3, 0, 0]) == [.buttonDown(.gesture)])
        #expect(decoder.decode(function: 0, parameters: [0x00, 0xC3, 0x00, 0xC4, 0, 0]) == [.buttonDown(.modeShift)])
        #expect(decoder.decode(function: 0, parameters: [0x00, 0xC4, 0, 0]) == [.buttonUp(.gesture)])
        #expect(decoder.decode(function: 0, parameters: [0, 0]) == [.buttonUp(.modeShift)])
    }

    @Test("unknown controls are ignored; a repeated report changes nothing")
    func unknownAndRepeat() {
        var decoder = DivertedControlsDecoder()
        #expect(decoder.decode(function: 0, parameters: [0x00, 0x52, 0, 0]).isEmpty)
        #expect(decoder.decode(function: 0, parameters: [0x00, 0xC3, 0, 0]) == [.buttonDown(.gesture)])
        #expect(decoder.decode(function: 0, parameters: [0x00, 0xC3, 0, 0]).isEmpty)
    }

    @Test("raw XY is signed big-endian; zero motion produces nothing")
    func rawXY() {
        var decoder = DivertedControlsDecoder()
        #expect(
            decoder.decode(function: 1, parameters: [0xFF, 0xFE, 0x00, 0x03]) == [
                .motion(dx: -2, dy: 3, source: .deviceRawXY)
            ]
        )
        #expect(decoder.decode(function: 1, parameters: [0, 0, 0, 0]).isEmpty)
        #expect(decoder.decode(function: 1, parameters: [0x01]).isEmpty)
    }

    @Test("releaseAll ends every press (disconnect safety)")
    func releaseAll() {
        var decoder = DivertedControlsDecoder()
        _ = decoder.decode(function: 0, parameters: [0x00, 0xC3, 0x00, 0xC4, 0, 0])
        #expect(decoder.releaseAll() == [.buttonUp(.gesture), .buttonUp(.modeShift)])
        #expect(decoder.releaseAll().isEmpty)
    }

    @Test("every divertible button maps back to its control")
    func controls() {
        #expect(DivertedControlsDecoder.control(for: .gesture) == 0x00C3)
        #expect(DivertedControlsDecoder.control(for: .modeShift) == 0x00C4)
        #expect(DivertedControlsDecoder.control(for: .middle) == nil)
    }
}
