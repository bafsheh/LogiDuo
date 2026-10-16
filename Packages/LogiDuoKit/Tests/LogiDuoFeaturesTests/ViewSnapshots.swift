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
        features: [.reprogrammableControls, .adjustableResolution, .smartShift, .hiResWheel, .thumbwheel, .battery],
        resolution: ResolutionRange(minimum: 200, maximum: 8000, step: 50).map { range in
            ResolutionState(current: 1000, range: range)
        },
        smartShift: .freeSpin
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
        try await renderSnapshot(DevicesView(model: model), name: "devices", size: CGSize(width: 820, height: 1100))
    }

    @Test("mapping editor")
    func mappingEditor() async throws {
        var configuration = LogiDuoConfiguration.standard
        configuration.defaultMappings = [
            ButtonMapping(trigger: .press(.back), action: .system(.missionControl)),
            ButtonMapping(trigger: .press(.middle), action: .media(.playPause)),
            ButtonMapping(trigger: .swipe(.middle, .left), action: .system(.previousSpace)),
            ButtonMapping(trigger: .horizontalScroll(.right), action: .shortcut(.nextTab)),
        ]
        let repository = FakeConfigurationRepository(configuration)
        let model = MappingEditorViewModel(repository: repository)
        let observing = Task { await model.observe() }
        await repository.finish()
        await observing.value
        try await renderSnapshot(
            MappingEditorView(model: model),
            name: "mappings",
            size: CGSize(width: 720, height: 820)
        )
    }

    @Test("profiles")
    func profiles() async throws {
        var configuration = LogiDuoConfiguration.standard
        configuration.profiles = [
            StoredProfile(
                id: ProfileFixtures.id("app.com.apple.Safari"),
                name: ProfileFixtures.name("Safari"),
                matchers: [ProfileFixtures.app("com.apple.Safari")]
            ),
            StoredProfile(
                id: ProfileFixtures.id("app.com.apple.mail"),
                name: ProfileFixtures.name("Mail"),
                matchers: [ProfileFixtures.app("com.apple.mail")],
                isEnabled: false
            ),
        ]
        let repository = FakeConfigurationRepository(configuration)
        let model = ProfilesViewModel(repository: repository)
        let observing = Task { await model.observe() }
        await repository.finish()
        await observing.value
        try await renderSnapshot(ProfilesView(model: model) { _ in }, name: "profiles")
    }

    @Test("Mouser import preview")
    func mouserImport() async throws {
        let preview = try MouserImporter.preview(Data(MouserImportFixture.version9.utf8))
        let model = MouserImportViewModel(service: SnapshotImporter(preview: preview))
        await model.loadDefault()
        try await renderSnapshot(
            MouserImportView(model: model) {},
            name: "import",
            size: CGSize(width: 520, height: 520)
        )
    }
}

private actor SnapshotImporter: MouserImportServicing {
    let preview: MouserImportPreview
    init(preview: MouserImportPreview) { self.preview = preview }
    func previewDefaultFile() -> Result<MouserImportPreview, MouserImportFailure> { .success(preview) }
    func preview(fileAt url: URL) -> Result<MouserImportPreview, MouserImportFailure> { .success(preview) }
    func apply(_ preview: MouserImportPreview) -> Result<Void, MouserImportFailure> { .success(()) }
    func canUndoImport() -> Bool { false }
    func undoImport() -> Bool { false }
}

private enum MouserImportFixture {
    static let version9 = #"""
        {"version": 9, "profiles": {"default": {"mappings": {"xbutton1": "alt_tab", "xbutton2": "alt_tab",
         "mode_shift": "mission_control", "middle": "none"}}},
         "settings": {"start_at_login": true, "dpi": 1000, "smart_shift_mode": "freespin", "gesture_threshold": 50}}
        """#
}
