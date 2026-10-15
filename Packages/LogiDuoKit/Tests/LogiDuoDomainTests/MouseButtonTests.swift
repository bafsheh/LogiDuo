import LogiDuoDomain
import Testing

@Suite("MouseButton")
struct MouseButtonTests {
    @Test("only primary and secondary are protected", arguments: MouseButton.allCases)
    func protection(button: MouseButton) {
        #expect(button.isProtected == (button == .primary || button == .secondary))
    }

    @Test("only the five standard buttons are system-reported", arguments: MouseButton.allCases)
    func systemReported(button: MouseButton) {
        let standard: Set<MouseButton> = [.primary, .secondary, .middle, .back, .forward]
        #expect(button.isSystemReported == standard.contains(button))
    }
}
