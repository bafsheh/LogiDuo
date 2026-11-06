import LogiDuoDomain
public import SwiftUI

/// Blueprint teardrop mouse with blueprint callout sheets for each control.
///
/// Palette is locked to ``BlueprintTheme`` only. Anchors sit on the drawing;
/// editable sheets hang on the right with leader lines.
struct MouseIllustrationView<Editor: View>: View {
    let layout: MouseIllustrationLayout
    let rows: [MappingRow]
    @Binding var selection: MouseIllustrationLayout.Hotspot?
    @ViewBuilder let editor: (MouseIllustrationLayout.Hotspot) -> Editor

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let mouseFrame = CGRect(
                x: size.width * 0.06, y: size.height * 0.06,
                width: size.width * 0.42, height: size.height * 0.82
            )
            ZStack(alignment: .topLeading) {
                MouseBlueprintBody(layout: layout, mouseFrame: mouseFrame)
                ForEach(Array(layout.hotspots.enumerated()), id: \.element.id) { index, spot in
                    callout(spot, index: index, mouseFrame: mouseFrame, canvas: size)
                }
            }
        }
        .aspectRatio(1.28, contentMode: .fit)
        .frame(maxHeight: 380)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(BlueprintTheme.inkMid, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("mappings.illustration", bundle: .module))
    }

    private func callout(
        _ spot: MouseIllustrationLayout.Hotspot,
        index: Int,
        mouseFrame: CGRect,
        canvas: CGSize
    ) -> some View {
        let mapped = isMapped(spot)
        let selected = selection == spot
        let anchor = CGPoint(
            x: mouseFrame.minX + spot.x * mouseFrame.width,
            y: mouseFrame.minY + spot.y * mouseFrame.height
        )
        let sheet = sheetFrame(index: index, count: layout.hotspots.count, canvas: canvas)
        return ZStack {
            leaderAndAnchor(anchor: anchor, sheet: sheet, selected: selected, mapped: mapped)
            sheetButton(spot, index: index, sheet: sheet, selected: selected, mapped: mapped)
        }
    }

    @ViewBuilder
    private func leaderAndAnchor(
        anchor: CGPoint, sheet: CGRect, selected: Bool, mapped: Bool
    ) -> some View {
        BlueprintLeader(from: anchor, to: CGPoint(x: sheet.minX, y: sheet.midY))
            .stroke(
                selected ? BlueprintTheme.inkHot : BlueprintTheme.inkMid,
                style: StrokeStyle(lineWidth: selected ? 1.4 : 1, lineCap: .round)
            )
            .allowsHitTesting(false)
        ZStack {
            Circle().strokeBorder(BlueprintTheme.ink, lineWidth: 1.2).frame(width: 12, height: 12)
            Circle()
                .fill(mapped || selected ? BlueprintTheme.inkHot : BlueprintTheme.plate)
                .frame(width: 5, height: 5)
            BlueprintCrosshair()
                .stroke(BlueprintTheme.inkMid, lineWidth: 0.8)
                .frame(width: 18, height: 18)
        }
        .position(anchor)
        .allowsHitTesting(false)
    }

    private func sheetButton(
        _ spot: MouseIllustrationLayout.Hotspot,
        index: Int,
        sheet: CGRect,
        selected: Bool,
        mapped: Bool
    ) -> some View {
        BlueprintSheetCallout(
            spot: spot, rows: rows(for: spot), index: index + 1,
            isSelected: selected, isMapped: mapped
        ) {
            selection = spot
        }
        .frame(width: sheet.width, height: sheet.height)
        .position(x: sheet.midX, y: sheet.midY)
        .popover(
            isPresented: Binding(get: { selection == spot }, set: { if !$0 { selection = nil } }),
            arrowEdge: .trailing
        ) {
            editor(spot).padding(16).frame(minWidth: 300)
        }
    }

    private func sheetFrame(index: Int, count: Int, canvas: CGSize) -> CGRect {
        let width = canvas.width * 0.44
        let height = min(40, canvas.height * 0.095)
        let top = canvas.height * 0.08
        let bottom = canvas.height * 0.88
        let span = max(bottom - top - height, 1)
        let step = count <= 1 ? 0 : span / CGFloat(count - 1)
        return CGRect(x: canvas.width * 0.52, y: top + CGFloat(index) * step, width: width, height: height)
    }

    private func rows(for spot: MouseIllustrationLayout.Hotspot) -> [MappingRow] {
        rows.filter { spot.triggers.contains($0.trigger) }
    }

    private func isMapped(_ spot: MouseIllustrationLayout.Hotspot) -> Bool {
        rows(for: spot).contains { $0.action != .passThrough }
    }
}

private struct BlueprintLeader: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let elbowX = from.x + (to.x - from.x) * 0.62
        path.addLine(to: CGPoint(x: elbowX, y: from.y))
        path.addLine(to: CGPoint(x: elbowX, y: to.y))
        path.addLine(to: to)
        return path
    }
}

private struct BlueprintCrosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + 4))
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY - 4))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.midY))
        path.move(to: CGPoint(x: rect.maxX - 4, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Blueprint callout sheet — same ink family as the plate.
private struct BlueprintSheetCallout: View {
    let spot: MouseIllustrationLayout.Hotspot
    let rows: [MappingRow]
    let index: Int
    let isSelected: Bool
    let isMapped: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) { sheetContent }
            .buttonStyle(.plain)
            .help(Text(spot.titleKey, bundle: .module))
            .accessibilityLabel(Text(spot.titleKey, bundle: .module))
            .accessibilityValue(actionSummary)
            .accessibilityHint(Text("mappings.illustration.hint", bundle: .module))
            .accessibilityIdentifier("mappings.hotspot.\(spot.id)")
    }

    private var sheetContent: some View {
        HStack(spacing: 0) {
            Text(String(format: "%02d", index))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected || isMapped ? BlueprintTheme.inkHot : BlueprintTheme.ink)
                .frame(width: 28).frame(maxHeight: .infinity)
                .background(BlueprintTheme.panel)
            Rectangle().fill(BlueprintTheme.inkMid).frame(width: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.titleKey, bundle: .module)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(BlueprintTheme.inkHot).lineLimit(1)
                actionSummary
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(BlueprintTheme.inkMid).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Spacer(minLength: 0)
            BlueprintStatusMark(isMapped: isMapped, isSelected: isSelected)
                .frame(width: 18, height: 18).padding(.trailing, 8)
        }
        .background(BlueprintTheme.panel.opacity(0.92))
        .overlay {
            Rectangle()
                .stroke(isSelected ? BlueprintTheme.inkHot : BlueprintTheme.inkMid, lineWidth: isSelected ? 1.6 : 1)
        }
    }

    private var actionSummary: Text {
        if rows.isEmpty { return Text("—") }
        return rows.reduce(Text("")) { text, row in
            text + Text(row.action.titleKey, bundle: .module) + Text(" ")
        }
    }
}

private struct BlueprintStatusMark: View {
    let isMapped: Bool
    let isSelected: Bool

    var body: some View {
        ZStack {
            Rectangle().stroke(BlueprintTheme.inkMid, lineWidth: 1)
            if isMapped || isSelected {
                BlueprintHatch().stroke(BlueprintTheme.inkHot, lineWidth: 1)
            }
        }
    }
}

private struct BlueprintHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 2))
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + 2))
        return path
    }
}
