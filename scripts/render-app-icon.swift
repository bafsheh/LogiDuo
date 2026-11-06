#!/usr/bin/env swift
import AppKit
import Foundation

/// Renders LogiDuo App Icon PNGs from a vector mark (no wordmark).
/// Usage: swift scripts/render-app-icon.swift

struct Palette {
    static let top = NSColor(srgbRed: 0.043, green: 0.110, blue: 0.141, alpha: 1)
    static let bottom = NSColor(srgbRed: 0.071, green: 0.239, blue: 0.267, alpha: 1)
    static let mouse = NSColor(srgbRed: 0.949, green: 0.984, blue: 0.980, alpha: 1)
    static let accent = NSColor(srgbRed: 0.180, green: 0.769, blue: 0.714, alpha: 1)
    static let ink = NSColor(srgbRed: 0.055, green: 0.125, blue: 0.153, alpha: 1)
}

func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
}

/// MX Master–inspired top view in top-left origin space (y grows down).
func mouseBody(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.move(to: point(0.58, 0.04, in: rect))
    path.addCurve(
        to: point(0.86, 0.16, in: rect),
        control1: point(0.70, 0.03, in: rect),
        control2: point(0.80, 0.07, in: rect)
    )
    path.addCurve(
        to: point(0.92, 0.46, in: rect),
        control1: point(0.92, 0.26, in: rect),
        control2: point(0.94, 0.36, in: rect)
    )
    path.addCurve(
        to: point(0.84, 0.80, in: rect),
        control1: point(0.90, 0.58, in: rect),
        control2: point(0.88, 0.72, in: rect)
    )
    path.addCurve(
        to: point(0.58, 0.96, in: rect),
        control1: point(0.78, 0.92, in: rect),
        control2: point(0.68, 0.97, in: rect)
    )
    path.addCurve(
        to: point(0.32, 0.90, in: rect),
        control1: point(0.48, 0.95, in: rect),
        control2: point(0.38, 0.94, in: rect)
    )
    path.addCurve(
        to: point(0.16, 0.68, in: rect),
        control1: point(0.22, 0.84, in: rect),
        control2: point(0.14, 0.78, in: rect)
    )
    path.addCurve(
        to: point(0.06, 0.46, in: rect),
        control1: point(0.12, 0.60, in: rect),
        control2: point(0.04, 0.54, in: rect)
    )
    path.addCurve(
        to: point(0.16, 0.28, in: rect),
        control1: point(0.08, 0.38, in: rect),
        control2: point(0.10, 0.32, in: rect)
    )
    path.addCurve(
        to: point(0.34, 0.10, in: rect),
        control1: point(0.22, 0.22, in: rect),
        control2: point(0.26, 0.12, in: rect)
    )
    path.addCurve(
        to: point(0.58, 0.04, in: rect),
        control1: point(0.42, 0.06, in: rect),
        control2: point(0.52, 0.04, in: rect)
    )
    path.closeSubpath()
    return path
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
    // Top-left origin for the unit paths below.
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: 1, y: -1)

    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let colors = [Palette.top.cgColor, Palette.bottom.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: CGFloat(pixels)),
        options: []
    )

    let mark = bounds.insetBy(dx: CGFloat(pixels) * 0.22, dy: CGFloat(pixels) * 0.12)
    cg.setFillColor(Palette.mouse.cgColor)
    cg.addPath(mouseBody(in: mark))
    cg.fillPath()

    let wheelW = mark.width * 0.10
    let wheelH = mark.height * 0.14
    let wheelRect = CGRect(
        x: mark.minX + mark.width * 0.53 - wheelW / 2,
        y: mark.minY + mark.height * 0.14,
        width: wheelW,
        height: wheelH
    )
    cg.setFillColor(Palette.ink.withAlphaComponent(0.42).cgColor)
    cg.addPath(CGPath(roundedRect: wheelRect, cornerWidth: wheelW / 2, cornerHeight: wheelW / 2, transform: nil))
    cg.fillPath()

    cg.setStrokeColor(Palette.ink.withAlphaComponent(0.30).cgColor)
    cg.setLineWidth(max(1, CGFloat(pixels) * 0.010))
    cg.setLineCap(.round)
    cg.move(to: point(0.58, 0.05, in: mark))
    cg.addLine(to: CGPoint(x: wheelRect.midX, y: wheelRect.minY))
    cg.strokePath()

    func duoArc(offset: CGFloat, alpha: CGFloat, width: CGFloat) {
        cg.setStrokeColor(Palette.accent.withAlphaComponent(alpha).cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.move(to: point(0.16 + offset, 0.28, in: mark))
        cg.addCurve(
            to: point(0.12 + offset, 0.70, in: mark),
            control1: point(0.06 + offset, 0.40, in: mark),
            control2: point(0.04 + offset, 0.56, in: mark)
        )
        cg.strokePath()
    }
    duoArc(offset: 0.00, alpha: 1.0, width: max(1.5, CGFloat(pixels) * 0.032))
    duoArc(offset: 0.07, alpha: 0.68, width: max(1.2, CGFloat(pixels) * 0.026))

    NSGraphicsContext.restoreGraphicsState()
    return rep
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
