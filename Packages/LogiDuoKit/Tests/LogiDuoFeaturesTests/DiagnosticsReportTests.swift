import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoFeatures

@Suite("DiagnosticsReport")
struct DiagnosticsReportTests {
    @Test("describes each device without identifiers")
    func text() throws {
        let model = try #require(ModelID(rawValue: 0xB034_0000_0000))
        let device = DeviceSnapshot(
            id: .fixture(1),
            name: "MX Master 3S",
            category: .mouse,
            transport: .bluetoothLowEnergy,
            link: .connected,
            battery: BatteryStatus(percentage: 65, isCharging: false),
            firmwareVersion: "RBM22.02_0009",
            model: model,
            features: [.battery],
            smartShift: .freeSpin
        )
        let report = DiagnosticsReport.text(for: [device], appVersion: "1.0", systemVersion: "26.0")

        #expect(report.contains("LogiDuo 1.0 on macOS 26.0"))
        #expect(report.contains("MX Master 3S (mouse)"))
        #expect(report.contains("firmware: RBM22.02_0009"))
        #expect(report.contains("battery: 65%"))
        #expect(!report.contains(DeviceID.fixture(1).rawValue))
    }

    @Test("an empty device list says so")
    func empty() {
        #expect(DiagnosticsReport.text(for: [], appVersion: "1", systemVersion: "x").contains("No devices."))
    }
}
