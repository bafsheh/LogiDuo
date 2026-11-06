public import SwiftUI

/// Shared brand colors for splash and in-app marks — locked to blueprint ink.
enum LogiDuoBrand {
    static let plate = Color(red: 0.04, green: 0.16, blue: 0.30)
    static let panel = Color(red: 0.06, green: 0.22, blue: 0.38)
    static let ink = Color(red: 0.55, green: 0.82, blue: 0.98)
    static let inkHot = Color(red: 0.78, green: 0.94, blue: 1.0)
}

/// Duo mark: blueprint keyboard + teardrop mouse with a lock node.
struct LogiDuoBrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            DuoBlueprintMark(size: geometry.size)
        }
        .aspectRatio(1.05, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct DuoBlueprintMark: View {
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            drawKeyboard(context: context, canvasSize: canvasSize)
            drawMouse(context: context, canvasSize: canvasSize)
            drawDuoNode(context: context, canvasSize: canvasSize)
        }
    }

    private func drawKeyboard(context: GraphicsContext, canvasSize: CGSize) {
        let keyW = canvasSize.width * 0.58
        let keyH = canvasSize.height * 0.42
        let rect = CGRect(
            x: canvasSize.width * 0.04,
            y: canvasSize.height * 0.42,
            width: keyW,
            height: keyH
        )
        let shape = RoundedRectangle(cornerRadius: keyH * 0.18, style: .continuous)
        context.fill(shape.path(in: rect), with: .color(LogiDuoBrand.ink.opacity(0.08)))
        context.stroke(shape.path(in: rect), with: .color(LogiDuoBrand.ink), lineWidth: 2)

        let capW = keyW * 0.13
        let capH = keyH * 0.28
        let gap = keyW * 0.07
        let startX = rect.midX - (capW * 3 + gap * 2) / 2
        for index in 0..<3 {
            let cap = CGRect(
                x: startX + CGFloat(index) * (capW + gap),
                y: rect.midY - capH / 2,
                width: capW,
                height: capH
            )
            let capShape = RoundedRectangle(cornerRadius: capH * 0.22, style: .continuous)
            context.stroke(
                capShape.path(in: cap),
                with: .color(LogiDuoBrand.inkHot.opacity(0.85)),
                lineWidth: 1.4
            )
        }
    }

    private func drawMouse(context: GraphicsContext, canvasSize: CGSize) {
        let mouseW = canvasSize.width * 0.34
        let mouseH = canvasSize.height * 0.62
        let rect = CGRect(
            x: canvasSize.width * 0.62,
            y: canvasSize.height * 0.06,
            width: mouseW,
            height: mouseH
        )
        let body = teardrop(in: rect)
        context.fill(body, with: .color(LogiDuoBrand.ink.opacity(0.08)))
        context.stroke(body, with: .color(LogiDuoBrand.ink), lineWidth: 2)

        let wheelW = mouseW * 0.22
        let wheelH = mouseH * 0.16
        let wheel = CGRect(
            x: rect.midX - wheelW / 2,
            y: rect.minY + mouseH * 0.18,
            width: wheelW,
            height: wheelH
        )
        context.stroke(
            RoundedRectangle(cornerRadius: wheelW / 2).path(in: wheel),
            with: .color(LogiDuoBrand.inkHot),
            lineWidth: 1.5
        )

        var center = Path()
        center.move(to: CGPoint(x: rect.midX, y: rect.minY + mouseH * 0.08))
        center.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - mouseH * 0.08))
        context.stroke(
            center,
            with: .color(LogiDuoBrand.ink.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
    }

    private func drawDuoNode(context: GraphicsContext, canvasSize: CGSize) {
        let node = CGPoint(x: canvasSize.width * 0.52, y: canvasSize.height * 0.48)
        let radius: CGFloat = max(6, canvasSize.width * 0.05)
        let ring = CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: ring), with: .color(LogiDuoBrand.plate))
        context.stroke(Path(ellipseIn: ring), with: .color(LogiDuoBrand.inkHot), lineWidth: 1.8)

        let tick = radius * 0.7
        var cross = Path()
        cross.move(to: CGPoint(x: node.x, y: node.y - radius - tick))
        cross.addLine(to: CGPoint(x: node.x, y: node.y - radius * 0.35))
        cross.move(to: CGPoint(x: node.x, y: node.y + radius * 0.35))
        cross.addLine(to: CGPoint(x: node.x, y: node.y + radius + tick))
        cross.move(to: CGPoint(x: node.x - radius - tick, y: node.y))
        cross.addLine(to: CGPoint(x: node.x - radius * 0.35, y: node.y))
        cross.move(to: CGPoint(x: node.x + radius * 0.35, y: node.y))
        cross.addLine(to: CGPoint(x: node.x + radius + tick, y: node.y))
        context.stroke(cross, with: .color(LogiDuoBrand.inkHot), lineWidth: 1.2)

        let dot: CGFloat = max(2, canvasSize.width * 0.018)
        context.fill(
            Path(ellipseIn: CGRect(x: node.x - dot / 2, y: node.y - dot / 2, width: dot, height: dot)),
            with: .color(LogiDuoBrand.inkHot)
        )
    }

    private func teardrop(in rect: CGRect) -> Path {
        var path = Path()
        let units: [(CGFloat, CGFloat)] = [
            (0.50, 0.008), (0.55, 0.008), (0.66, 0.04), (0.76, 0.12),
            (0.76, 0.12), (0.90, 0.24), (0.99, 0.44), (0.96, 0.64),
            (0.96, 0.64), (0.93, 0.82), (0.76, 0.98), (0.50, 0.992),
            (0.50, 0.992), (0.24, 0.98), (0.07, 0.82), (0.04, 0.64),
            (0.04, 0.64), (0.01, 0.44), (0.10, 0.24), (0.24, 0.12),
            (0.24, 0.12), (0.34, 0.04), (0.45, 0.008), (0.50, 0.008),
        ]
        func point(_ unit: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(x: rect.minX + unit.0 * rect.width, y: rect.minY + unit.1 * rect.height)
        }
        path.move(to: point(units[0]))
        for index in stride(from: 0, to: units.count, by: 4) {
            path.addCurve(
                to: point(units[index + 3]),
                control1: point(units[index + 1]),
                control2: point(units[index + 2])
            )
        }
        path.closeSubpath()
        return path
    }
}

/// Brief branded splash shown over the main window on first appearance.
public struct SplashView: View {
    @Binding var isPresented: Bool

    @State private var markOpacity = 0.0
    @State private var markScale = 0.92
    @State private var copyOpacity = 0.0

    /// Creates a splash that dismisses itself after a short intro.
    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [LogiDuoBrand.plate, LogiDuoBrand.panel],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            BlueprintSplashGrid()
                .opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                LogiDuoBrandMark()
                    .frame(width: 148, height: 140)
                    .scaleEffect(markScale)
                    .opacity(markOpacity)

                VStack(spacing: 6) {
                    Text("splash.title", bundle: .module)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(LogiDuoBrand.inkHot)
                    Text("splash.tagline", bundle: .module)
                        .font(.system(size: 15, weight: .regular, design: .monospaced))
                        .foregroundStyle(LogiDuoBrand.ink.opacity(0.75))
                }
                .opacity(copyOpacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("splash.accessibility", bundle: .module))
        .task { await playIntro() }
    }

    @MainActor
    private func playIntro() async {
        let clock = ContinuousClock()
        withAnimation(.easeOut(duration: 0.45)) {
            markOpacity = 1
            markScale = 1
        }
        try? await clock.sleep(for: .milliseconds(180))
        withAnimation(.easeOut(duration: 0.35)) {
            copyOpacity = 1
        }
        try? await clock.sleep(for: .milliseconds(900))
        withAnimation(.easeIn(duration: 0.28)) {
            markOpacity = 0
            copyOpacity = 0
            markScale = 1.04
        }
        try? await clock.sleep(for: .milliseconds(280))
        isPresented = false
    }
}

private struct BlueprintSplashGrid: View {
    var body: some View {
        Canvas { context, size in
            let step = min(size.width, size.height) * 0.06
            var x: CGFloat = 0
            while x <= size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(LogiDuoBrand.ink.opacity(0.18)), lineWidth: 0.6)
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(LogiDuoBrand.ink.opacity(0.18)), lineWidth: 0.6)
                y += step
            }
        }
    }
}
