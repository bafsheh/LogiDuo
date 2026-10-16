import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoSystem
import Testing

/// Reads the system-wide list of installed event taps (documented `CGGetEventTapList`).
enum TapRegistry {
    /// Active (event-modifying) taps owned by process `pid`.
    static func activeTaps(of pid: pid_t) -> Int {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return 0 }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return 0 }
        return taps.prefix(Int(count)).filter { $0.tappingProcess == pid && $0.enabled && $0.options == .defaultTap }
            .count
    }
}

extension LiveSystemSuites {
    @Suite("System: event taps as macOS sees them", .timeLimit(.minutes(2)))
    struct SystemTapRegistryTests {
        private let pid = ProcessInfo.processInfo.processIdentifier

        @Test("the engine's tap exists in macOS only between start and stop, across repeated cycles")
        func tapLifetime() {
            let engine = LiveInputEngine(executor: SyntheticInputExecutor(poster: CoreGraphicsEventPoster()))
            let before = TapRegistry.activeTaps(of: pid)
            for _ in 0..<10 {
                engine.start()
                #expect(TapRegistry.activeTaps(of: pid) == before + 1)
                engine.stop()
                #expect(TapRegistry.activeTaps(of: pid) == before)
            }
        }

        @Test("the LogiDuo app installs no event tap at launch and leaves none after quitting")
        func appLaunchAndQuit() async throws {
            let app = try #require(
                Self.builtApp(),
                "build the app first (make build); looked in build/DerivedData"
            )
            let configuration = NSWorkspaceLaunchProxy.configuration()
            let launched = try await NSWorkspaceLaunchProxy.launch(app, configuration: configuration)
            defer { launched.forceTerminate() }
            let pid = launched.processIdentifier
            #expect(await Self.waitForLaunch(launched))
            print("[system] LogiDuo pid=\(pid) active taps after launch: \(TapRegistry.activeTaps(of: pid))")
            #expect(TapRegistry.activeTaps(of: pid) == 0)

            launched.terminate()
            #expect(await Self.waitForExit(launched))
            #expect(TapRegistry.activeTaps(of: pid) == 0)
        }

        static func builtApp() -> URL? {
            var directory = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { directory.deleteLastPathComponent() }
            let app = directory.appendingPathComponent("build/DerivedData/Build/Products/Debug/LogiDuo.app")
            return FileManager.default.fileExists(atPath: app.path) ? app : nil
        }

        static func waitForLaunch(_ app: RunningApp) async -> Bool {
            await poll { app.isFinishedLaunching }
        }

        static func waitForExit(_ app: RunningApp) async -> Bool {
            await poll { app.isTerminated }
        }

        /// Polls a system condition with a bounded deadline (the app runs in another process).
        static func poll(_ condition: @Sendable () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(15)
            while clock.now < deadline {
                if condition() { return true }
                try? await clock.sleep(for: .milliseconds(100))
            }
            return condition()
        }
    }
}

extension LiveSystemSuites.SystemTapRegistryTests {
    @Test("regression: releasing a started engine without stop removes its tap from macOS")
    func releasedEngine() {
        let before = TapRegistry.activeTaps(of: pid)
        do {
            let engine = LiveInputEngine(executor: SyntheticInputExecutor(poster: CoreGraphicsEventPoster()))
            engine.start()
            #expect(TapRegistry.activeTaps(of: pid) == before + 1)
        }
        #expect(TapRegistry.activeTaps(of: pid) == before)
    }
}

extension LiveSystemSuites.SystemTapRegistryTests {
    /// A helper that installs a pass-through active tap and runs until killed.
    private static let crashHelperSource = """
        import CoreGraphics
        import Foundation
        let mask = CGEventMask(1) << CGEventMask(CGEventType.otherMouseDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { exit(2) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        print("ready"); fflush(stdout)
        CFRunLoopRun()
        """

    @Test("a process killed with SIGKILL loses its event tap: macOS removes it with the process")
    func crashRemovesTap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logiduo-crash-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("main.swift")
        let binary = directory.appendingPathComponent("helper")
        try Self.crashHelperSource.write(to: source, atomically: true, encoding: .utf8)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-O", source.path, "-o", binary.path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0, "helper did not compile")

        let helper = Process()
        helper.executableURL = binary
        let output = Pipe()
        helper.standardOutput = output
        try helper.run()
        let ready = String(bytes: output.fileHandleForReading.availableDataUntilNewline(), encoding: .utf8) ?? ""
        try #require(ready.hasPrefix("ready"), "helper could not install its tap")
        let pid = helper.processIdentifier
        #expect(TapRegistry.activeTaps(of: pid) == 1)

        kill(pid, SIGKILL)
        helper.waitUntilExit()

        print("[system] helper pid=\(pid) killed; taps now: \(TapRegistry.activeTaps(of: pid))")
        #expect(TapRegistry.activeTaps(of: pid) == 0)
    }
}

extension FileHandle {
    /// Reads until a newline (or end of file).
    func availableDataUntilNewline() -> Data {
        var data = Data()
        while let byte = try? read(upToCount: 1), !byte.isEmpty {
            data.append(byte)
            if byte.first == 0x0A { break }
        }
        return data
    }
}
