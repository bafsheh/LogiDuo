import AppKit
import Foundation
import LogiDuoDomain
import LogiDuoTestSupport
import SwiftUI
import Testing

@testable import LogiDuoFeatures

/// Where to write view renderings for visual review; snapshots are skipped without it.
let snapshotDirectory = ProcessInfo.processInfo.environment["LOGIDUO_SNAPSHOT_DIR"]

/// Renders `view` in an offscreen window to a PNG named `name` (no screen recording involved).
@MainActor
func renderSnapshot(_ view: some View, name: String, size: CGSize = CGSize(width: 820, height: 560)) async throws {
    guard let snapshotDirectory else { return }
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.background))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.backgroundColor = .windowBackgroundColor
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    // Let SwiftUI finish a couple of update passes (tasks, lists).
    for _ in 0..<3 { await Task.yield() }
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        Issue.record("could not render \(name)")
        return
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try png.write(to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent("\(name).png"))
}

@MainActor
@Suite("View snapshots (opt-in: LOGIDUO_SNAPSHOT_DIR)", .enabled(if: snapshotDirectory != nil))
struct ViewSnapshots {
    static let mouse = DeviceSnapshot(
        id: .fixture(1),
        name: "MX Master 3S",
        category: .mouse,
        transport: .bluetoothLowEnergy,
        link: .connected,
        battery: BatteryStatus(percentage: 65, isCharging: false),
        firmwareVersion: "RBM22.02_0009",
        features: [.reprogrammableControls, .adjustableResolution, .smartShift, .hiResWheel, .thumbwheel, .battery]
    )
    static let keyboard = DeviceSnapshot(
        id: .fixture(2),
        name: "MX Keys Wireless Keyboard",
        category: .keyboard,
        transport: .bluetoothLowEnergy,
        link: .connected,
        battery: BatteryStatus(percentage: 50, isCharging: true),
        firmwareVersion: "MPK12.01_0013",
        features: [.reprogrammableControls, .battery, .backlight, .fnInversion]
    )

    @Test("device dashboard")
    func dashboard() async throws {
        let service = FakeDeviceService()
        let model = DevicesViewModel(service: service, router: AppRouter())
        service.send([Self.mouse, Self.keyboard])
        service.finish()
        await model.observe()
        try await renderSnapshot(DevicesView(model: model), name: "devices")
    }
}
