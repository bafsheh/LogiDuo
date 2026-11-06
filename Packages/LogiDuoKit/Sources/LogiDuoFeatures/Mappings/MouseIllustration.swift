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
        Hotspot(id: "middle", triggers: [.press(.middle)], x: 0.54, y: 0.22),
        Hotspot(id: "modeShift", triggers: [.press(.modeShift)], x: 0.54, y: 0.36),
        Hotspot(id: "thumbwheel", triggers: [.horizontalScroll(.left), .horizontalScroll(.right)], x: 0.14, y: 0.48),
        Hotspot(id: "forward", triggers: [.press(.forward)], x: 0.12, y: 0.60),
        Hotspot(id: "back", triggers: [.press(.back)], x: 0.14, y: 0.70),
        Hotspot(id: "gesture", triggers: [.press(.gesture)], x: 0.22, y: 0.82),
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
                MouseBodyShape()
                    .fill(.quaternary)
                MouseThumbShelfShape()
                    .fill(Color.primary.opacity(0.04))
                MouseWheelShape()
                    .fill(Color.secondary.opacity(0.35))
                MouseSeamShape()
                    .stroke(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                MouseBodyShape()
                    .stroke(.secondary, lineWidth: 1.5)
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
        .aspectRatio(0.68, contentMode: .fit)
        .frame(maxHeight: 320)
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

/// Unit-space helper shared by the mouse drawing shapes.
private enum MouseGeometry {
    static func point(_ x: Double, _ y: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}

/// Vector outline of an MX Master–style mouse (top view, thumb on the left).
private struct MouseBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: Double, _ y: Double) -> CGPoint { MouseGeometry.point(x, y, in: rect) }
        var path = Path()
        path.move(to: at(0.58, 0.04))
        path.addCurve(to: at(0.86, 0.16), control1: at(0.70, 0.03), control2: at(0.80, 0.07))
        path.addCurve(to: at(0.92, 0.46), control1: at(0.92, 0.26), control2: at(0.94, 0.36))
        path.addCurve(to: at(0.84, 0.80), control1: at(0.90, 0.58), control2: at(0.88, 0.72))
        path.addCurve(to: at(0.58, 0.96), control1: at(0.78, 0.92), control2: at(0.68, 0.97))
        path.addCurve(to: at(0.32, 0.90), control1: at(0.48, 0.95), control2: at(0.38, 0.94))
        path.addCurve(to: at(0.16, 0.68), control1: at(0.22, 0.84), control2: at(0.14, 0.78))
        path.addCurve(to: at(0.06, 0.46), control1: at(0.12, 0.60), control2: at(0.04, 0.54))
        path.addCurve(to: at(0.16, 0.28), control1: at(0.08, 0.38), control2: at(0.10, 0.32))
        path.addCurve(to: at(0.34, 0.10), control1: at(0.22, 0.22), control2: at(0.26, 0.12))
        path.addCurve(to: at(0.58, 0.04), control1: at(0.42, 0.06), control2: at(0.52, 0.04))
        path.closeSubpath()
        return path
    }
}

/// Soft fill on the thumb shelf so the left contour reads as a rest, not a blob.
private struct MouseThumbShelfShape: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: Double, _ y: Double) -> CGPoint { MouseGeometry.point(x, y, in: rect) }
        var path = Path()
        path.move(to: at(0.22, 0.28))
        path.addCurve(to: at(0.18, 0.52), control1: at(0.16, 0.34), control2: at(0.14, 0.44))
        path.addCurve(to: at(0.22, 0.78), control1: at(0.16, 0.62), control2: at(0.16, 0.72))
        path.addCurve(to: at(0.36, 0.86), control1: at(0.26, 0.84), control2: at(0.32, 0.86))
        path.addCurve(to: at(0.34, 0.34), control1: at(0.42, 0.70), control2: at(0.40, 0.46))
        path.addCurve(to: at(0.22, 0.28), control1: at(0.30, 0.28), control2: at(0.26, 0.28))
        path.closeSubpath()
        return path
    }
}

/// Scroll-wheel capsule near the nose, on the button midline.
private struct MouseWheelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = CGSize(width: 0.09 * rect.width, height: 0.13 * rect.height)
        let origin = MouseGeometry.point(0.56 - 0.045, 0.13, in: rect)
        return Path(roundedRect: CGRect(origin: origin, size: size), cornerRadius: size.width / 2)
    }
}

/// Primary / secondary button seam into the wheel.
private struct MouseSeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: MouseGeometry.point(0.56, 0.05, in: rect))
        path.addLine(to: MouseGeometry.point(0.56, 0.13, in: rect))
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
