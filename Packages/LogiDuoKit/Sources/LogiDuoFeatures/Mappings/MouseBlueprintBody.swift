public import SwiftUI

/// Blueprint plate: grid, teardrop contour, centerline, orthographic wheel well.
struct MouseBlueprintBody: View {
    let layout: MouseIllustrationLayout
    let mouseFrame: CGRect

    private var sideControlCount: Int {
        layout.hotspots.filter { $0.kind == .sideButton || $0.kind == .thumbwheel }.count
    }

    var body: some View {
        Canvas { context, canvasSize in
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(BlueprintTheme.plate))
            drawGrid(context: context, canvasSize: canvasSize)
            drawFrame(context: context, canvasSize: canvasSize)
            drawMouse(context: context)
            drawTitleBlock(context: context, canvasSize: canvasSize)
        }
        .accessibilityHidden(true)
    }

    private func drawGrid(context: GraphicsContext, canvasSize: CGSize) {
        let step = min(canvasSize.width, canvasSize.height) * 0.055
        var x: CGFloat = 0
        while x <= canvasSize.width {
            strokeVertical(context: context, x: x, height: canvasSize.height, step: step)
            x += step
        }
        var y: CGFloat = 0
        while y <= canvasSize.height {
            strokeHorizontal(context: context, y: y, width: canvasSize.width, step: step)
            y += step
        }
    }

    private func strokeVertical(context: GraphicsContext, x: CGFloat, height: CGFloat, step: CGFloat) {
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: height))
        let major = Int((x / step).rounded()).isMultiple(of: 5)
        context.stroke(
            line,
            with: .color(major ? BlueprintTheme.ink.opacity(0.18) : BlueprintTheme.inkDim),
            lineWidth: major ? 0.9 : 0.5
        )
    }

    private func strokeHorizontal(context: GraphicsContext, y: CGFloat, width: CGFloat, step: CGFloat) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: width, y: y))
        let major = Int((y / step).rounded()).isMultiple(of: 5)
        context.stroke(
            line,
            with: .color(major ? BlueprintTheme.ink.opacity(0.18) : BlueprintTheme.inkDim),
            lineWidth: major ? 0.9 : 0.5
        )
    }

    private func drawFrame(context: GraphicsContext, canvasSize: CGSize) {
        let frame = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 6, dy: 6)
        context.stroke(Path(frame), with: .color(BlueprintTheme.inkMid), lineWidth: 1.2)
        for corner in [
            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY),
        ] {
            drawCornerTick(context: context, corner: corner, frame: frame)
        }
    }

    private func drawCornerTick(context: GraphicsContext, corner: CGPoint, frame: CGRect) {
        let tick: CGFloat = 10
        var horizontal = Path()
        horizontal.move(to: CGPoint(x: corner.x - (corner.x == frame.minX ? 0 : tick), y: corner.y))
        horizontal.addLine(to: CGPoint(x: corner.x + (corner.x == frame.minX ? tick : 0), y: corner.y))
        var vertical = Path()
        vertical.move(to: CGPoint(x: corner.x, y: corner.y - (corner.y == frame.minY ? 0 : tick)))
        vertical.addLine(to: CGPoint(x: corner.x, y: corner.y + (corner.y == frame.minY ? tick : 0)))
        context.stroke(horizontal, with: .color(BlueprintTheme.ink), lineWidth: 1.4)
        context.stroke(vertical, with: .color(BlueprintTheme.ink), lineWidth: 1.4)
    }

    private func drawMouse(context: GraphicsContext) {
        let body = MouseOutline.path(
            layout.silhouette, in: mouseFrame, sideControlCount: sideControlCount
        )
        context.fill(body, with: .color(BlueprintTheme.ink.opacity(0.05)))
        context.stroke(body, with: .color(BlueprintTheme.ink), lineWidth: 2)

        let inner = MouseOutline.path(
            layout.silhouette,
            in: mouseFrame.insetBy(dx: mouseFrame.width * 0.04, dy: mouseFrame.height * 0.032),
            sideControlCount: sideControlCount
        )
        context.stroke(inner, with: .color(BlueprintTheme.inkMid), lineWidth: 1)

        let midX = mouseFrame.minX + mouseFrame.width * (layout.silhouette == .ergonomic ? 0.52 : 0.50)
        var center = Path()
        center.move(to: CGPoint(x: midX, y: mouseFrame.minY + mouseFrame.height * 0.03))
        center.addLine(to: CGPoint(x: midX, y: mouseFrame.maxY - mouseFrame.height * 0.03))
        context.stroke(
            center,
            with: .color(BlueprintTheme.inkMid),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )

        let well = CGRect(
            x: midX - mouseFrame.width * 0.04,
            y: mouseFrame.minY + mouseFrame.height * 0.11,
            width: mouseFrame.width * 0.08,
            height: mouseFrame.height * 0.11
        )
        context.stroke(Path(well), with: .color(BlueprintTheme.ink), lineWidth: 1.3)
        var hatch = Path()
        var hatchX = well.minX
        while hatchX < well.maxX {
            hatch.move(to: CGPoint(x: hatchX, y: well.minY))
            hatch.addLine(to: CGPoint(x: hatchX, y: well.maxY))
            hatchX += 3
        }
        context.stroke(hatch, with: .color(BlueprintTheme.ink.opacity(0.35)), lineWidth: 0.6)
    }

    private func drawTitleBlock(context: GraphicsContext, canvasSize: CGSize) {
        let block = CGRect(x: 14, y: canvasSize.height - 28, width: min(160, canvasSize.width * 0.35), height: 16)
        context.stroke(Path(block), with: .color(BlueprintTheme.inkMid), lineWidth: 0.9)
        let label = Text("MOUSE — TOP VIEW")
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(BlueprintTheme.inkMid)
        context.draw(label, at: CGPoint(x: block.minX + 8, y: block.midY), anchor: .leading)
    }
}
