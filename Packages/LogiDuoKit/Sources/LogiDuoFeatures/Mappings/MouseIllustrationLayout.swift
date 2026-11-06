public import LogiDuoDomain
import SwiftUI

/// Body outline used for the mapping illustration.
public enum MouseSilhouette: Hashable, Sendable {
    /// Symmetric shell — mice with little or no left-side hardware.
    case compact
    /// Asymmetric shell with a left thumb shelf — mice with side controls.
    case ergonomic
}

/// How a control is drawn on the product-style mouse.
public enum MouseControlKind: Hashable, Sendable {
    /// Vertical scroll wheel.
    case wheel
    /// Small button under the wheel (mode shift).
    case modeShift
    /// Horizontal thumb wheel on the left shelf.
    case thumbwheel
    /// One of the stacked left-side buttons.
    case sideButton
}

/// Where each mappable control sits on the drawing, in unit coordinates (0…1). Pure data,
/// independent of HID and of the drawing itself.
public struct MouseIllustrationLayout: Hashable, Sendable {
    /// One clickable control on the mouse body.
    public struct Hotspot: Hashable, Sendable, Identifiable {
        /// A stable identifier.
        public let id: String
        /// The triggers edited from this control.
        public let triggers: [InputTrigger]
        /// How the control is drawn.
        public let kind: MouseControlKind
        /// The control's centre in unit coordinates.
        public let x: Double
        /// The control's centre in unit coordinates.
        public let y: Double
        /// Hit / draw width in unit coordinates.
        public let width: Double
        /// Hit / draw height in unit coordinates.
        public let height: Double
    }

    /// Outline style driven by which side controls exist.
    public let silhouette: MouseSilhouette
    /// The spots.
    public let hotspots: [Hotspot]

    /// Whether the drawing should carve a left-side control channel.
    public var hasSideRail: Bool {
        hotspots.contains { $0.kind == .sideButton || $0.kind == .thumbwheel }
    }

    /// MX Master–class layout (kept for snapshots and as a full-feature fixture).
    public static let mxMaster = make(
        buttons: [.middle, .back, .forward, .gesture, .modeShift],
        hasThumbwheel: true
    )

    /// Builds a layout from the buttons and thumbwheel the mouse actually has.
    public static func make(buttons: Set<MouseButton>, hasThumbwheel: Bool) -> MouseIllustrationLayout {
        let remappable = buttons.filter { !$0.isProtected }
        let sideButtons = Self.sideOrder.filter(remappable.contains)
        let silhouette: MouseSilhouette = (hasThumbwheel || !sideButtons.isEmpty) ? .ergonomic : .compact
        // Wheel sits on the seam, slightly toward the right button plate.
        let midX = silhouette == .ergonomic ? 0.54 : 0.50
        var hotspots: [Hotspot] = []

        if remappable.contains(.middle) {
            hotspots.append(
                Hotspot(
                    id: "middle", triggers: [.press(.middle)], kind: .wheel,
                    x: midX, y: 0.17, width: 0.085, height: 0.115
                )
            )
        }
        if remappable.contains(.modeShift) {
            hotspots.append(
                Hotspot(
                    id: "modeShift", triggers: [.press(.modeShift)], kind: .modeShift,
                    x: midX, y: 0.29, width: 0.10, height: 0.045
                )
            )
        }

        var leftItems: [(id: String, triggers: [InputTrigger], kind: MouseControlKind)] = []
        if hasThumbwheel {
            leftItems.append((
                "thumbwheel",
                [.horizontalScroll(.left), .horizontalScroll(.right)],
                .thumbwheel
            ))
        }
        for button in sideButtons {
            leftItems.append((button.rawValue, [.press(button)], .sideButton))
        }
        hotspots.append(contentsOf: placeOnThumbArc(leftItems, silhouette: silhouette))
        return MouseIllustrationLayout(silhouette: silhouette, hotspots: hotspots)
    }

    /// Derives buttons and thumbwheel from discovered ``MouseCapabilities``.
    public static func make(
        capabilities: MouseCapabilities,
        deviceButtonsAvailable: Bool
    ) -> MouseIllustrationLayout {
        var buttons = Set<MouseButton>()
        for button in MouseButton.allCases where !button.isProtected {
            switch capabilities.remapAvailability(for: button) {
            case .available: buttons.insert(button)
            case .unavailable: break
            case .pending:
                if button.isSystemReported || deviceButtonsAvailable {
                    buttons.insert(button)
                }
            }
        }
        if case .undiscovered = capabilities.divertableButtons {
            buttons.subtract([.dpiSwitch, .thumb, .sensePanel])
            if deviceButtonsAvailable {
                buttons.formUnion([.gesture, .modeShift])
            }
        }
        let hasThumbwheel: Bool =
            switch capabilities.thumbwheel {
            case .supported: true
            case .unsupported: false
            case .undiscovered: true
            }
        return make(buttons: buttons, hasThumbwheel: hasThumbwheel)
    }

    private static let sideOrder: [MouseButton] = [
        .forward, .back, .gesture, .thumb, .dpiSwitch, .sensePanel,
    ]

    /// Thumb-rest arc (unit space): sits on the left teardrop bay edge.
    /// Upper = closer to the nose; lower = toward the rear.
    private static let ergonomicThumbArc: [(x: Double, y: Double)] = [
        (0.18, 0.34),
        (0.12, 0.44),
        (0.09, 0.54),
        (0.10, 0.64),
        (0.13, 0.74),
        (0.18, 0.82),
    ]

    private static let compactThumbArc: [(x: Double, y: Double)] = [
        (0.18, 0.36),
        (0.14, 0.48),
        (0.14, 0.60),
        (0.16, 0.72),
        (0.20, 0.82),
    ]

    /// Places side controls along the thumb shelf curve (thumbwheel first when present).
    private static func placeOnThumbArc(
        _ items: [(id: String, triggers: [InputTrigger], kind: MouseControlKind)],
        silhouette: MouseSilhouette
    ) -> [Hotspot] {
        guard !items.isEmpty else { return [] }
        let arc = silhouette == .ergonomic ? ergonomicThumbArc : compactThumbArc
        let anchors = sampleArc(arc, count: items.count)
        return zip(items, anchors).map { item, anchor in
            let isWheel = item.kind == .thumbwheel
            return Hotspot(
                id: item.id,
                triggers: item.triggers,
                kind: item.kind,
                x: anchor.x,
                y: anchor.y,
                width: isWheel ? 0.135 : 0.095,
                height: isWheel ? 0.060 : 0.070
            )
        }
    }

    /// Evenly picks `count` points along a polyline arc (including endpoints).
    private static func sampleArc(
        _ arc: [(x: Double, y: Double)],
        count: Int
    ) -> [(x: Double, y: Double)] {
        guard count > 0 else { return [] }
        if count == 1 {
            let mid = arc[arc.count / 2]
            return [mid]
        }
        if count >= arc.count { return Array(arc.prefix(count)) }
        return (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            let position = fraction * Double(arc.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, arc.count - 1)
            let local = position - Double(lower)
            let start = arc[lower]
            let end = arc[upper]
            return (
                start.x + (end.x - start.x) * local,
                start.y + (end.y - start.y) * local
            )
        }
    }
}

extension MouseIllustrationLayout.Hotspot {
    var titleKey: LocalizedStringKey {
        switch id {
        case "thumbwheel": "mappings.hotspot.thumbwheel"
        default: triggers.first?.titleKey ?? "mappings.hotspot.thumbwheel"
        }
    }
}
