import SwiftUI

/// Blueprint teardrop mouse outlines (unit space, tip / nose at the top).
enum MouseOutline {
    /// Body path for `silhouette`, scaled into `rect`.
    static func path(
        _ silhouette: MouseSilhouette,
        in rect: CGRect,
        sideControlCount: Int = 2
    ) -> Path {
        path(from: curves(silhouette, sideControlCount: sideControlCount), in: rect)
    }

    private static func curves(_ silhouette: MouseSilhouette, sideControlCount: Int) -> [Cubic] {
        switch silhouette {
        case .compact: teardrop
        case .ergonomic: ergonomicTeardrop(sideControlCount: sideControlCount)
        }
    }

    /// Pointed tip, full rear bulb — reads as a drafting teardrop, not an oval.
    private static let teardrop: [Cubic] = [
        Cubic((0.50, 0.008), (0.55, 0.008), (0.66, 0.04), (0.76, 0.12)),
        Cubic((0.76, 0.12), (0.90, 0.24), (0.99, 0.44), (0.96, 0.64)),
        Cubic((0.96, 0.64), (0.93, 0.82), (0.76, 0.98), (0.50, 0.992)),
        Cubic((0.50, 0.992), (0.24, 0.98), (0.07, 0.82), (0.04, 0.64)),
        Cubic((0.04, 0.64), (0.01, 0.44), (0.10, 0.24), (0.24, 0.12)),
        Cubic((0.24, 0.12), (0.34, 0.04), (0.45, 0.008), (0.50, 0.008)),
    ]

    /// Teardrop with a carved left thumb bay sized to the side-control count.
    private static func ergonomicTeardrop(sideControlCount: Int) -> [Cubic] {
        let bay = 0.04 + 0.01 * Double(min(max(sideControlCount, 1), 5))
        return [
            Cubic((0.54, 0.008), (0.60, 0.008), (0.72, 0.04), (0.82, 0.12)),
            Cubic((0.82, 0.12), (0.94, 0.24), (1.01, 0.44), (0.97, 0.64)),
            Cubic((0.97, 0.64), (0.93, 0.82), (0.76, 0.98), (0.54, 0.992)),
            Cubic((0.54, 0.992), (0.32, 0.98), (0.16, 0.88), (0.10, 0.74)),
            Cubic((0.10, 0.74), (0.05, 0.62), (0.00 - bay, 0.48), (0.06, 0.34)),
            Cubic((0.06, 0.34), (0.12, 0.22), (0.26, 0.10), (0.40, 0.035)),
            Cubic((0.40, 0.035), (0.46, 0.015), (0.50, 0.008), (0.54, 0.008)),
        ]
    }

    private struct Cubic {
        let start: (Double, Double)
        let control1: (Double, Double)
        let control2: (Double, Double)
        let end: (Double, Double)

        init(
            _ start: (Double, Double),
            _ control1: (Double, Double),
            _ control2: (Double, Double),
            _ end: (Double, Double)
        ) {
            self.start = start
            self.control1 = control1
            self.control2 = control2
            self.end = end
        }
    }

    private static func path(from curves: [Cubic], in rect: CGRect) -> Path {
        var path = Path()
        guard let first = curves.first else { return path }
        path.move(to: point(first.start, in: rect))
        for curve in curves {
            path.addCurve(
                to: point(curve.end, in: rect),
                control1: point(curve.control1, in: rect),
                control2: point(curve.control2, in: rect)
            )
        }
        path.closeSubpath()
        return path
    }

    private static func point(_ unit: (Double, Double), in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unit.0 * rect.width, y: rect.minY + unit.1 * rect.height)
    }
}
