public import SwiftUI

/// Shared brand colors for splash and in-app marks. Semantic system colors stay
/// elsewhere; these are only for the LogiDuo identity surfaces.
enum LogiDuoBrand {
    static let ink = Color(red: 0.043, green: 0.110, blue: 0.141)
    static let deep = Color(red: 0.071, green: 0.239, blue: 0.267)
    static let mist = Color(red: 0.949, green: 0.984, blue: 0.980)
    static let accent = Color(red: 0.180, green: 0.769, blue: 0.714)
}

/// Top-down ergonomic mouse silhouette used by the splash and brand mark.
/// Unit coordinates: nose at the top, thumb shelf on the left.
struct LogiDuoMouseMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.58, 0.04))
        path.addCurve(to: p(0.86, 0.16), control1: p(0.70, 0.03), control2: p(0.80, 0.07))
        path.addCurve(to: p(0.92, 0.46), control1: p(0.92, 0.26), control2: p(0.94, 0.36))
        path.addCurve(to: p(0.84, 0.80), control1: p(0.90, 0.58), control2: p(0.88, 0.72))
        path.addCurve(to: p(0.58, 0.96), control1: p(0.78, 0.92), control2: p(0.68, 0.97))
        path.addCurve(to: p(0.32, 0.90), control1: p(0.48, 0.95), control2: p(0.38, 0.94))
        path.addCurve(to: p(0.16, 0.68), control1: p(0.22, 0.84), control2: p(0.14, 0.78))
        path.addCurve(to: p(0.06, 0.46), control1: p(0.12, 0.60), control2: p(0.04, 0.54))
        path.addCurve(to: p(0.16, 0.28), control1: p(0.08, 0.38), control2: p(0.10, 0.32))
        path.addCurve(to: p(0.34, 0.10), control1: p(0.22, 0.22), control2: p(0.26, 0.12))
        path.addCurve(to: p(0.58, 0.04), control1: p(0.42, 0.06), control2: p(0.52, 0.04))
        path.closeSubpath()
        return path
    }
}

/// The LogiDuo brand mark: mouse silhouette + duo accent arcs.
struct LogiDuoBrandMark: View {
    var bodyFilled: Color = LogiDuoBrand.mist
    var accent: Color = LogiDuoBrand.accent
    var ink: Color = LogiDuoBrand.ink

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LogiDuoMouseMarkShape()
                    .fill(bodyFilled)
                Capsule()
                    .fill(ink.opacity(0.42))
                    .frame(width: size.width * 0.10, height: size.height * 0.14)
                    .position(x: size.width * 0.52, y: size.height * 0.22)
                DuoAccentArcs()
                    .stroke(
                        accent,
                        style: StrokeStyle(lineWidth: max(2, size.width * 0.055), lineCap: .round)
                    )
                DuoAccentArcs(offset: 0.07)
                    .stroke(
                        accent.opacity(0.68),
                        style: StrokeStyle(lineWidth: max(1.5, size.width * 0.045), lineCap: .round)
                    )
            }
        }
        .aspectRatio(0.72, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Twin gesture arcs along the thumb shelf — the "duo" signal.
private struct DuoAccentArcs: Shape {
    var offset: Double = 0

    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.18 + offset, 0.30))
        path.addCurve(
            to: p(0.14 + offset, 0.68),
            control1: p(0.08 + offset, 0.40),
            control2: p(0.06 + offset, 0.54)
        )
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
                colors: [LogiDuoBrand.ink, LogiDuoBrand.deep],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [LogiDuoBrand.accent.opacity(0.22), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 280
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                LogiDuoBrandMark()
                    .frame(width: 120, height: 168)
                    .scaleEffect(markScale)
                    .opacity(markOpacity)

                VStack(spacing: 6) {
                    Text("splash.title", bundle: .module)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(LogiDuoBrand.mist)
                    Text("splash.tagline", bundle: .module)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(LogiDuoBrand.mist.opacity(0.72))
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
