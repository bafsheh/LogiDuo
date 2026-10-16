public import LogiDuoDomain
public import SwiftUI

/// Where each mappable control sits on the drawing, in unit coordinates (0…1). Pure data,
/// independent of HID and of the drawing itself.
public struct MouseIllustrationLayout: Hashable, Sendable {
    /// One clickable spot.
    public struct Hotspot: Hashable, Sendable, Identifiable {
        /// A stable identifier.
        public let id: String
        /// The triggers edited from this spot (the thumb wheel has two directions).
        public let triggers: [InputTrigger]
        /// The spot's centre in unit coordinates.
        public let x: Double
        /// The spot's centre in unit coordinates.
        public let y: Double
    }

    /// The spots.
    public let hotspots: [Hotspot]

    /// An MX Master–style mouse seen from above (thumb side on the left).
    public static let mxMaster = MouseIllustrationLayout(hotspots: [
        Hotspot(id: "middle", triggers: [.press(.middle)], x: 0.56, y: 0.17),
        Hotspot(id: "modeShift", triggers: [.press(.modeShift)], x: 0.56, y: 0.33),
        Hotspot(id: "thumbwheel", triggers: [.horizontalScroll(.left), .horizontalScroll(.right)], x: 0.13, y: 0.45),
        Hotspot(id: "forward", triggers: [.press(.forward)], x: 0.10, y: 0.56),
        Hotspot(id: "back", triggers: [.press(.back)], x: 0.10, y: 0.66),
        Hotspot(id: "gesture", triggers: [.press(.gesture)], x: 0.17, y: 0.80),
    ])
}

/// A drawn mouse whose controls can be clicked to edit their mappings.
///
/// Accessibility: every spot is a button named after its control and current action,
/// so the drawing is fully usable with VoiceOver and Full Keyboard Access; the
/// conventional list below it offers the same editing.
struct MouseIllustrationView<Editor: View>: View {
    let layout: MouseIllustrationLayout
    let rows: [MappingRow]
    @Binding var selection: MouseIllustrationLayout.Hotspot?
    /// The editor shown in a popover for the selected spot.
    @ViewBuilder let editor: (MouseIllustrationLayout.Hotspot) -> Editor

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                MouseShape()
                    .fill(.quaternary)
                    .overlay(MouseShape().stroke(.secondary, lineWidth: 1.5))
                    .accessibilityHidden(true)
                ForEach(layout.hotspots) { spot in
                    HotspotButton(spot: spot, rows: rows(for: spot), isSelected: selection == spot) {
                        selection = spot
                    }
                    .popover(
                        isPresented: Binding(get: { selection == spot }, set: { if !$0 { selection = nil } }),
                        arrowEdge: .trailing
                    ) {
                        editor(spot).padding(16).frame(minWidth: 300)
                    }
                    .position(x: spot.x * size.width, y: spot.y * size.height)
                }
            }
        }
        .aspectRatio(0.62, contentMode: .fit)
        .frame(maxHeight: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("mappings.illustration", bundle: .module))
    }

    private func rows(for spot: MouseIllustrationLayout.Hotspot) -> [MappingRow] {
        rows.filter { spot.triggers.contains($0.trigger) }
    }
}

/// One clickable control.
private struct HotspotButton: View {
    let spot: MouseIllustrationLayout.Hotspot
    let rows: [MappingRow]
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Circle()
                .fill(isMapped ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(isSelected ? Color.primary : .clear, lineWidth: 2).padding(-4))
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .help(Text(spot.titleKey, bundle: .module))
        .accessibilityLabel(Text(spot.titleKey, bundle: .module))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(Text("mappings.illustration.hint", bundle: .module))
        .accessibilityIdentifier("mappings.hotspot.\(spot.id)")
    }

    private var isMapped: Bool { rows.contains { $0.action != .passThrough } }

    private var accessibilityValue: Text {
        rows.reduce(Text("")) { text, row in text + Text(row.action.titleKey, bundle: .module) + Text(" ") }
    }
}

/// The outline of the mouse, drawn in a unit square scaled to the frame.
private struct MouseShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.55, 0.02))
        path.addCurve(to: point(0.96, 0.30), control1: point(0.80, 0.02), control2: point(0.96, 0.12))
        path.addCurve(to: point(0.80, 0.96), control1: point(0.98, 0.60), control2: point(0.94, 0.90))
        path.addCurve(to: point(0.28, 0.96), control1: point(0.64, 1.0), control2: point(0.42, 1.0))
        path.addCurve(to: point(0.04, 0.62), control1: point(0.12, 0.92), control2: point(0.02, 0.80))
        path.addCurve(to: point(0.20, 0.10), control1: point(0.04, 0.40), control2: point(0.08, 0.20))
        path.addCurve(to: point(0.55, 0.02), control1: point(0.30, 0.04), control2: point(0.42, 0.02))
        path.closeSubpath()
        // The split between the two main buttons and the wheel slot.
        path.move(to: point(0.56, 0.04))
        path.addLine(to: point(0.56, 0.12))
        path.addRoundedRect(
            in: CGRect(origin: point(0.52, 0.12), size: CGSize(width: 0.08 * rect.width, height: 0.11 * rect.height)),
            cornerSize: CGSize(width: 4, height: 4)
        )
        return path
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
