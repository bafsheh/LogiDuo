import Foundation
import LogiDuoDomain
import LogiDuoHID
import LogiDuoHIDPP
import LogiDuoPersistence
import LogiDuoSystem
import Testing

/// The experiment runs only when armed for exactly this operation and unit, and the
/// operator confirms the checks only a person can make. `make hardware-test` never arms it.
private let environment = ProcessInfo.processInfo.environment
private let experimentArmed =
    environment["LOGIDUO_PHYSICAL_WRITE"] == "00C3-once"
    && environment["LOGIDUO_EXPECTED_UNIT"].flatMap { UInt32($0, radix: 16) } != nil
    && environment["LOGIDUO_OPERATOR_CONFIRMS"] == "trackpad-ready,phase4-done"

/// The first physical configuration write (runbook: LogiDuo-internal/phase5/first-write-runbook.md).
///
/// MX Master 3S over Bluetooth, ReprogControlsV4, gesture button 0x00C3: one temporary
/// button-only divert, then exact restoration, each verified by read-back, through
/// ``SingleUseDivertExperiment`` and the app's own restoration journal (so a crash leaves
/// a record the Recovery screen can restore). Every precondition the harness can check is
/// re-checked here; any failure aborts before the write.
@Suite(
    "Physical: first write experiment (disarmed unless explicitly armed)",
    .enabled(if: experimentArmed),
    .serialized
)
struct PhysicalWriteExperimentTests {
    private typealias Channel = HIDPPChannel<ContinuousClock>

    @Test("gesture button: one temporary divert and exact restoration")
    func divertOnce() async throws {
        let expectedUnit = try #require(environment["LOGIDUO_EXPECTED_UNIT"].flatMap { UInt32($0, radix: 16) })
        let conflicts = await MainActor.run { ConflictingSoftwareMonitor.current() }
        try #require(conflicts.isEmpty, "quit \(conflicts) first")
        let channel = try await Self.openMouse()
        defer { Task { await channel.close() } }
        let target = try await Self.identity(channel, expectedUnit: expectedUnit)
        try await Self.health(channel, target: target)
        let ledger = RestorationLedger(store: FileRestorationJournalStore())
        try #require(await ledger.load() == .clean, "the restoration journal must be clean")

        let session = ExperimentSession()
        let token = await session.authorize(.mxMaster3SGestureDivertOnce, expectedUnit: UnitID(rawValue: expectedUnit))
        let experiment = SingleUseDivertExperiment(
            connection: channel,
            target: target,
            transport: .bluetoothLowEnergy,
            ledger: ledger,
            session: session,
            timeout: .seconds(2)
        )
        let report = await experiment.run(token)
        try await Self.verify(report, channel: channel, target: target, ledger: ledger)
    }

    /// The MX Master 3S over Bluetooth LE, on a transport without the read-only guard.
    private static func openMouse() async throws -> Channel {
        let descriptor = try #require(
            presentHIDPPEndpoints().first { candidate in
                candidate.hardware.product.rawValue == 0xB034
                    && HIDInterfaceClassifier.role(of: candidate)
                        == .directDevice(.bluetoothLowEnergy, .bluetoothLowEnergy)
            },
            "MX Master 3S over Bluetooth LE not found"
        )
        let transport = try HIDDeviceMonitor.openSnapshotTransport(
            registryID: descriptor.registryID,
            framing: .bluetoothLowEnergy
        )
        let channel = HIDPPChannel(transport: transport, clock: ContinuousClock())
        await channel.start()
        return channel
    }

    /// Feature locations and the verified unit (read-only).
    private static func identity(_ channel: Channel, expectedUnit: UInt32) async throws -> ConfigurableDevice {
        let reprog = try #require(try await locate(.reprogControlsV4, channel))
        let info = try #require(try await locate(.deviceInformation, channel))
        let information = try await DeviceInformationFeature.information(
            via: channel,
            index: info,
            deviceIndex: .direct,
            timeout: .seconds(2)
        )
        let physical = try #require(information.physicalID)
        try #require(physical.unit.rawValue == expectedUnit, "a different unit is connected")
        return ConfigurableDevice(
            identity: DeviceID(physical: physical),
            physical: physical,
            deviceIndex: .direct,
            reprogIndex: reprog,
            informationIndex: info
        )
    }

    /// Battery and the gesture button's original state (read-only).
    private static func health(_ channel: Channel, target: ConfigurableDevice) async throws {
        let battery = try #require(try await locate(.unifiedBattery, channel))
        let level = try await BatteryFeature.reading(
            feature: .unifiedBattery,
            via: channel,
            index: battery,
            deviceIndex: .direct
        )
        try #require((level.percentage ?? 0) >= 30, "battery below 30 %")
        let original = try await ReprogControlsFeature.reporting(
            of: 0x00C3,
            via: channel,
            index: target.reprogIndex,
            deviceIndex: .direct
        )
        print(
            "[experiment] preflight: battery=\(level.percentage ?? -1)% original=0x\(String(original.flags, radix: 16))"
        )
        try #require(original.isNative, "the gesture button is not in its native state")
    }

    /// Reports every step and confirms, independently, that the device is native and the journal clean.
    private static func verify(
        _ report: ExperimentReport,
        channel: Channel,
        target: ConfigurableDevice,
        ledger: RestorationLedger
    ) async throws {
        for step in report.steps { print("[experiment] \(step)") }
        print("[experiment] outcome: \(report.outcome)")
        let final = try await ReprogControlsFeature.reporting(
            of: 0x00C3,
            via: channel,
            index: target.reprogIndex,
            deviceIndex: .direct,
            timeout: .seconds(2)
        )
        print("[experiment] independent final read: flags=0x\(String(final.flags, radix: 16)) native=\(final.isNative)")
        let pending = await ledger.pendingEntryCount
        if report.outcome != .completed || !final.isNative || pending != 0 {
            print("[experiment] RECOVERY REQUIRED: stop testing; open LogiDuo › Recovery. The journal is kept.")
        }
        #expect(report.outcome == .completed)
        #expect(final.isNative)
        #expect(pending == 0)
    }

    private static func locate(_ feature: FeatureID, _ channel: Channel) async throws -> FeatureIndex? {
        try await RootFeature.location(of: feature, via: channel, device: .direct, timeout: .seconds(2))?.index
    }
}
