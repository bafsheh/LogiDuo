import LogiDuoDomain
import Testing

@Suite("CapabilityStatus")
struct CapabilityStatusTests {
    @Test(
        "a discovered newer status always wins",
        arguments: [
            (CapabilityStatus<Int>.supported(1), CapabilityStatus<Int>.unsupported, CapabilityStatus<Int>.unsupported),
            (.unsupported, .supported(2), .supported(2)),
            (.supported(1), .supported(2), .supported(2)),
            (.undiscovered, .supported(3), .supported(3)),
        ]
    )
    func discoveredWins(current: CapabilityStatus<Int>, newer: CapabilityStatus<Int>, expected: CapabilityStatus<Int>) {
        #expect(current.refined(by: newer) == expected)
    }

    @Test(
        "an undiscovered newer status never erases knowledge",
        arguments: [
            CapabilityStatus<Int>.supported(1), .unsupported, .undiscovered,
        ]
    )
    func undiscoveredKeepsKnowledge(current: CapabilityStatus<Int>) {
        #expect(current.refined(by: .undiscovered) == current)
    }

    @Test("reports support and discovery")
    func flags() {
        #expect(CapabilityStatus.supported(1).isSupported)
        #expect(CapabilityStatus.supported(1).detail == 1)
        #expect(!CapabilityStatus<Int>.unsupported.isSupported)
        #expect(CapabilityStatus<Int>.unsupported.isDiscovered)
        #expect(!CapabilityStatus<Int>.undiscovered.isDiscovered)
        #expect(CapabilityStatus<Int>.undiscovered.detail == nil)
    }
}

@Suite("ResolutionRange")
struct ResolutionRangeTests {
    @Test(
        "rejects invalid ranges",
        arguments: [
            (0, 100, 50), (-100, 100, 50), (200, 100, 50), (200, 8000, 0), (200, 8010, 50),
        ]
    )
    func invalid(minimum: Int, maximum: Int, step: Int) {
        #expect(ResolutionRange(minimum: minimum, maximum: maximum, step: step) == nil)
    }

    @Test("accepts a single-value range")
    func singleValue() throws {
        let range = try #require(ResolutionRange(minimum: 1000, maximum: 1000, step: 50))
        #expect(range.contains(1000))
        #expect(range.nearestSupported(to: 4000) == 1000)
    }

    @Test(
        "contains only whole steps inside the bounds",
        arguments: [
            (200, true), (250, true), (8000, true), (225, false), (150, false), (8050, false),
        ]
    )
    func containment(dpi: Int, expected: Bool) throws {
        let range = try #require(ResolutionRange(minimum: 200, maximum: 8000, step: 50))
        #expect(range.contains(dpi) == expected)
    }

    @Test(
        "snaps to the nearest supported value",
        arguments: [
            (0, 200), (224, 200), (225, 250), (1601, 1600), (99_999, 8000),
        ]
    )
    func snapping(dpi: Int, expected: Int) throws {
        let range = try #require(ResolutionRange(minimum: 200, maximum: 8000, step: 50))
        #expect(range.nearestSupported(to: dpi) == expected)
    }
}

@Suite("MouseCapabilities")
struct MouseCapabilitiesTests {
    private static let gestureOnly = GestureCapability(buttons: [.gesture], supportsDirectionalSwipes: true)

    @Test("protected buttons are never remappable, even if reported divertable")
    func protectedButtons() {
        let capabilities = MouseCapabilities(divertableButtons: .supported([.primary, .gesture]))

        #expect(capabilities.remapAvailability(for: .primary) == .unavailable)
        #expect(capabilities.remapAvailability(for: .secondary) == .unavailable)
        #expect(capabilities.issues == [.protectedButtonDivertable(.primary)])
    }

    @Test(
        "system-reported buttons are remappable before discovery",
        arguments: [
            MouseButton.middle, .back, .forward,
        ]
    )
    func systemButtonsAvailable(button: MouseButton) {
        #expect(MouseCapabilities.undiscovered.remapAvailability(for: button) == .available)
        #expect(MouseCapabilities(divertableButtons: .unsupported).remapAvailability(for: button) == .available)
    }

    @Test(
        "diverted buttons depend on discovery",
        arguments: [
            (CapabilityStatus<Set<MouseButton>>.undiscovered, Availability.pending),
            (.unsupported, .unavailable),
            (.supported([.modeShift]), .unavailable),
            (.supported([.gesture, .modeShift]), .available),
        ]
    )
    func divertedButtons(status: CapabilityStatus<Set<MouseButton>>, expected: Availability) {
        #expect(MouseCapabilities(divertableButtons: status).remapAvailability(for: .gesture) == expected)
    }

    @Test("gesture capability rejects empty or protected button sets")
    func gestureCapabilityValidation() {
        #expect(GestureCapability(buttons: [], supportsDirectionalSwipes: false) == nil)
        #expect(GestureCapability(buttons: [.gesture, .primary], supportsDirectionalSwipes: false) == nil)
        #expect(GestureCapability(buttons: [.middle], supportsDirectionalSwipes: false) != nil)
    }

    @Test("flags gestures that cannot be diverted")
    func inconsistentGestures() throws {
        let gestures = try #require(Self.gestureOnly)

        let none = MouseCapabilities(divertableButtons: .unsupported, gestures: .supported(gestures))
        let missing = MouseCapabilities(divertableButtons: .supported([.modeShift]), gestures: .supported(gestures))
        let pending = MouseCapabilities(divertableButtons: .undiscovered, gestures: .supported(gestures))

        #expect(none.issues == [.gesturesWithoutDivertableButtons])
        #expect(missing.issues == [.gestureButtonNotDivertable(.gesture)])
        #expect(pending.issues.isEmpty)
    }

    @Test("independent capabilities combine without issues")
    func independentCombination() throws {
        let capabilities = MouseCapabilities(
            divertableButtons: .supported([.gesture, .thumb]),
            resolution: .supported(try #require(ResolutionRange(minimum: 200, maximum: 8000, step: 50))),
            smartShift: .supported(SmartShiftCapability(supportsTunableTorque: true)),
            highResolutionWheel: .supported(ScrollWheelCapability(supportsInversion: true)),
            thumbwheel: .unsupported,
            gestures: .supported(try #require(Self.gestureOnly)),
            battery: .supported(BatteryReporting(reportsPercentage: true)),
            haptics: .unsupported
        )

        #expect(capabilities.issues.isEmpty)
        #expect(capabilities.remapAvailability(for: .thumb) == .available)
        #expect(capabilities.remapAvailability(for: .sensePanel) == .unavailable)
    }

    @Test("runtime discovery refines catalog expectations field by field")
    func refinement() throws {
        let range = try #require(ResolutionRange(minimum: 200, maximum: 4000, step: 50))
        let catalog = MouseCapabilities(
            resolution: .supported(range),
            smartShift: .supported(SmartShiftCapability(supportsTunableTorque: false)),
            thumbwheel: .supported(ScrollWheelCapability(supportsInversion: true))
        )
        let runtime = MouseCapabilities(
            smartShift: .unsupported,
            battery: .supported(BatteryReporting(reportsPercentage: false))
        )

        let merged = catalog.refined(by: runtime)

        #expect(merged.resolution == .supported(range))
        #expect(merged.smartShift == .unsupported)
        #expect(merged.thumbwheel == catalog.thumbwheel)
        #expect(merged.battery == runtime.battery)
        #expect(merged.haptics == .undiscovered)
    }
}

@Suite("DeviceCapabilities")
struct DeviceCapabilitiesTests {
    @Test("the capability model follows the device category", arguments: DeviceCategory.allCases)
    func modelPerCategory(category: DeviceCategory) {
        let capabilities = DeviceCapabilities(undiscoveredFor: category)
        switch category {
        case .mouse: #expect(capabilities == .mouse(.undiscovered))
        case .keyboard: #expect(capabilities == .keyboard(.undiscovered))
        case .receiver, .unclassified: #expect(capabilities == DeviceCapabilities.none)
        }
    }

    @Test("refines keyboard capabilities independently of mouse ones")
    func keyboardRefinement() throws {
        let current = DeviceCapabilities.keyboard(KeyboardCapabilities(backlight: .supported(.present)))
        let newer = DeviceCapabilities.keyboard(KeyboardCapabilities(functionKeyInversion: .unsupported))

        let merged = try current.refined(by: newer)

        #expect(
            merged
                == .keyboard(KeyboardCapabilities(functionKeyInversion: .unsupported, backlight: .supported(.present)))
        )
    }

    @Test("refusing to combine capabilities of different device kinds")
    func kindMismatch() {
        #expect(throws: CapabilityKindMismatch.self) {
            try DeviceCapabilities.mouse(.undiscovered).refined(by: .keyboard(.undiscovered))
        }
    }
}
