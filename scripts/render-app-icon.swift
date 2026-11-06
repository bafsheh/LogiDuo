#!/usr/bin/env swift
import AppKit
import Foundation

/// Renders LogiDuo App Icon PNGs: blueprint keyboard + teardrop mouse (no wordmark).
/// Usage: swift scripts/render-app-icon.swift

struct Palette {
    static let plate = NSColor(srgbRed: 0.04, green: 0.16, blue: 0.30, alpha: 1)
    static let panel = NSColor(srgbRed: 0.06, green: 0.22, blue: 0.38, alpha: 1)
    static let ink = NSColor(srgbRed: 0.55, green: 0.82, blue: 0.98, alpha: 1)
    static let inkHot = NSColor(srgbRed: 0.78, green: 0.94, blue: 1.0, alpha: 1)
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("bitmap")
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("context") }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: 1, y: -1)

    let s = CGFloat(pixels)
    drawPlate(cg: cg, size: s)
    drawGrid(cg: cg, size: s)

    // Content inset so the system squircle mask keeps the mark clear.
    let pad = s * 0.16
    let field = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)

    drawKeyboard(cg: cg, field: field, size: s)
    drawMouse(cg: cg, field: field, size: s)
    drawDuoNode(cg: cg, field: field, size: s)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawPlate(cg: CGContext, size: CGFloat) {
    let colors = [Palette.panel.cgColor, Palette.plate.cgColor] as CFArray
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
}

func drawGrid(cg: CGContext, size: CGFloat) {
    let step = size * 0.08
    cg.setStrokeColor(Palette.ink.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(max(1, size * 0.004))
    var x: CGFloat = 0
    while x <= size {
        cg.move(to: CGPoint(x: x, y: 0))
        cg.addLine(to: CGPoint(x: x, y: size))
        x += step
    }
    var y: CGFloat = 0
    while y <= size {
        cg.move(to: CGPoint(x: 0, y: y))
        cg.addLine(to: CGPoint(x: size, y: y))
        y += step
    }
    cg.strokePath()

    // Major ticks every 5 cells.
    cg.setStrokeColor(Palette.ink.withAlphaComponent(0.28).cgColor)
    cg.setLineWidth(max(1.2, size * 0.006))
    x = 0
    var index = 0
    while x <= size {
        if index.isMultiple(of: 5) {
            cg.move(to: CGPoint(x: x, y: 0))
            cg.addLine(to: CGPoint(x: x, y: size))
        }
        x += step
        index += 1
    }
    y = 0
    index = 0
    while y <= size {
        if index.isMultiple(of: 5) {
            cg.move(to: CGPoint(x: 0, y: y))
            cg.addLine(to: CGPoint(x: size, y: y))
        }
        y += step
        index += 1
    }
    cg.strokePath()
}

func drawKeyboard(cg: CGContext, field: CGRect, size: CGFloat) {
    let keyW = field.width * 0.58
    let keyH = field.height * 0.34
    let keyRect = CGRect(
        x: field.minX + field.width * 0.02,
        y: field.minY + field.height * 0.46,
        width: keyW,
        height: keyH
    )
    let radius = keyH * 0.18

    cg.setFillColor(Palette.ink.withAlphaComponent(0.08).cgColor)
    cg.addPath(CGPath(roundedRect: keyRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.fillPath()

    cg.setStrokeColor(Palette.ink.cgColor)
    cg.setLineWidth(max(2, size * 0.022))
    cg.addPath(CGPath(roundedRect: keyRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.strokePath()

    // Three key caps as blueprint slots.
    let capW = keyW * 0.13
    let capH = keyH * 0.28
    let capY = keyRect.midY - capH / 2
    let gap = keyW * 0.07
    let startX = keyRect.midX - (capW * 3 + gap * 2) / 2
    cg.setStrokeColor(Palette.inkHot.withAlphaComponent(0.85).cgColor)
    cg.setLineWidth(max(1.4, size * 0.012))
    for index in 0..<3 {
        let x = startX + CGFloat(index) * (capW + gap)
        let cap = CGRect(x: x, y: capY, width: capW, height: capH)
        let capRadius = capH * 0.22
        cg.addPath(CGPath(roundedRect: cap, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil))
        cg.strokePath()
    }
}

func drawMouse(cg: CGContext, field: CGRect, size: CGFloat) {
    let mouseW = field.width * 0.36
    let mouseH = field.height * 0.62
    let mouseRect = CGRect(
        x: field.maxX - mouseW - field.width * 0.01,
        y: field.minY + field.height * 0.04,
        width: mouseW,
        height: mouseH
    )

    let path = teardropPath(in: mouseRect)
    cg.setFillColor(Palette.ink.withAlphaComponent(0.08).cgColor)
    cg.addPath(path)
    cg.fillPath()

    cg.setStrokeColor(Palette.ink.cgColor)
    cg.setLineWidth(max(2, size * 0.022))
    cg.addPath(path)
    cg.strokePath()

    // Inner contour.
    let inset = mouseRect.insetBy(dx: mouseW * 0.12, dy: mouseH * 0.08)
    cg.setStrokeColor(Palette.ink.withAlphaComponent(0.45).cgColor)
    cg.setLineWidth(max(1.2, size * 0.01))
    cg.addPath(teardropPath(in: inset))
    cg.strokePath()

    // Wheel well.
    let wheelW = mouseW * 0.20
    let wheelH = mouseH * 0.14
    let wheel = CGRect(
        x: mouseRect.midX - wheelW / 2,
        y: mouseRect.minY + mouseH * 0.18,
        width: wheelW,
        height: wheelH
    )
    cg.setStrokeColor(Palette.inkHot.cgColor)
    cg.setLineWidth(max(1.5, size * 0.012))
    cg.addPath(CGPath(roundedRect: wheel, cornerWidth: wheelW / 2, cornerHeight: wheelW / 2, transform: nil))
    cg.strokePath()

    // Dashed centerline.
    cg.setStrokeColor(Palette.ink.withAlphaComponent(0.55).cgColor)
    cg.setLineWidth(max(1, size * 0.008))
    cg.setLineDash(phase: 0, lengths: [max(3, size * 0.018), max(3, size * 0.018)])
    cg.move(to: CGPoint(x: mouseRect.midX, y: mouseRect.minY + mouseH * 0.08))
    cg.addLine(to: CGPoint(x: mouseRect.midX, y: mouseRect.maxY - mouseH * 0.08))
    cg.strokePath()
    cg.setLineDash(phase: 0, lengths: [])
}

func teardropPath(in rect: CGRect) -> CGPath {
    // Unit-space teardrop (nose at top), matching MouseOutline.
    let units: [(CGFloat, CGFloat)] = [
        (0.50, 0.008), (0.55, 0.008), (0.66, 0.04), (0.76, 0.12),
        (0.76, 0.12), (0.90, 0.24), (0.99, 0.44), (0.96, 0.64),
        (0.96, 0.64), (0.93, 0.82), (0.76, 0.98), (0.50, 0.992),
        (0.50, 0.992), (0.24, 0.98), (0.07, 0.82), (0.04, 0.64),
        (0.04, 0.64), (0.01, 0.44), (0.10, 0.24), (0.24, 0.12),
        (0.24, 0.12), (0.34, 0.04), (0.45, 0.008), (0.50, 0.008),
    ]
    func point(_ u: (CGFloat, CGFloat)) -> CGPoint {
        CGPoint(x: rect.minX + u.0 * rect.width, y: rect.minY + u.1 * rect.height)
    }
    let path = CGMutablePath()
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

func drawDuoNode(cg: CGContext, field: CGRect, size: CGFloat) {
    // Crosshair node where keyboard and mouse meet — the “duo” lock.
    let node = CGPoint(
        x: field.minX + field.width * 0.52,
        y: field.minY + field.height * 0.48
    )
    let radius = size * 0.035
    cg.setFillColor(Palette.plate.cgColor)
    cg.fillEllipse(in: CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2))
    cg.setStrokeColor(Palette.inkHot.cgColor)
    cg.setLineWidth(max(1.8, size * 0.016))
    cg.strokeEllipse(in: CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2))

    let tick = size * 0.028
    cg.setStrokeColor(Palette.inkHot.cgColor)
    cg.setLineWidth(max(1.2, size * 0.01))
    cg.move(to: CGPoint(x: node.x, y: node.y - radius - tick))
    cg.addLine(to: CGPoint(x: node.x, y: node.y - radius * 0.35))
    cg.move(to: CGPoint(x: node.x, y: node.y + radius * 0.35))
    cg.addLine(to: CGPoint(x: node.x, y: node.y + radius + tick))
    cg.move(to: CGPoint(x: node.x - radius - tick, y: node.y))
    cg.addLine(to: CGPoint(x: node.x - radius * 0.35, y: node.y))
    cg.move(to: CGPoint(x: node.x + radius * 0.35, y: node.y))
    cg.addLine(to: CGPoint(x: node.x + radius + tick, y: node.y))
    cg.strokePath()

    cg.setFillColor(Palette.inkHot.cgColor)
    let dot = size * 0.012
    cg.fillEllipse(in: CGRect(x: node.x - dot / 2, y: node.y - dot / 2, width: dot, height: dot))
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-app-icon", code: 1)
    }
    try data.write(to: url, options: .atomic)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let files: [(file: String, px: Int)] = [
    ("AppIcon-16.png", 16),
    ("AppIcon-16@2x.png", 32),
    ("AppIcon-32.png", 32),
    ("AppIcon-32@2x.png", 64),
    ("AppIcon-128.png", 128),
    ("AppIcon-128@2x.png", 256),
    ("AppIcon-256.png", 256),
    ("AppIcon-256@2x.png", 512),
    ("AppIcon-512.png", 512),
    ("AppIcon-512@2x.png", 1024),
]

for item in files {
    try writePNG(drawIcon(pixels: item.px), to: outDir.appendingPathComponent(item.file))
    fputs("wrote \(item.file) (\(item.px)px)\n", stderr)
}

let design = root.appendingPathComponent("Design")
try FileManager.default.createDirectory(at: design, withIntermediateDirectories: true)
try writePNG(drawIcon(pixels: 1024), to: design.appendingPathComponent("AppIcon-1024.png"))
fputs("wrote Design/AppIcon-1024.png\n", stderr)
