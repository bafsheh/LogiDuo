import CoreGraphics
import Foundation
import LogiDuoDomain
import Testing

@testable import LogiDuoSystem

@Suite("SyntheticEventPlanner")
struct SyntheticEventPlannerTests {
    private static func key(_ raw: UInt16) -> KeyCode {
        guard let key = KeyCode(rawValue: raw) else { preconditionFailure("valid") }
        return key
    }

    private static func stroke(_ raw: UInt16, _ modifiers: KeyModifiers = []) -> [SyntheticEventSpec] {
        [.key(key(raw), isDown: true, modifiers: modifiers), .key(key(raw), isDown: false, modifiers: modifiers)]
    }

    @Test("synthetic presses and releases map one to one")
    func pressRelease() {
        #expect(SyntheticEventPlanner.plan(.pressSynthetic(.middle)).events == [.mouseButton(.middle, isDown: true)])
        #expect(SyntheticEventPlanner.plan(.releaseSynthetic(.middle)).events == [.mouseButton(.middle, isDown: false)])
    }

    @Test("a native click replay is a full click of a system-reported button only")
    func replay() {
        #expect(
            SyntheticEventPlanner.plan(.replayNativeClick(.back)).events == [
                .mouseButton(.back, isDown: true), .mouseButton(.back, isDown: false),
            ]
        )
        #expect(SyntheticEventPlanner.plan(.replayNativeClick(.gesture)).gap == .notReplayable(.gesture))
    }

    @Test("shortcuts become paired key strokes, repeated where the preset says so")
    func shortcuts() {
        #expect(SyntheticEventPlanner.plan(.perform(.shortcut(.copy))).events == Self.stroke(0x08, .command))
        #expect(
            SyntheticEventPlanner.plan(.perform(.shortcut(.zoomIn))).events
                == Array(
                    [Self.stroke(0x18, .command), Self.stroke(0x18, .command), Self.stroke(0x18, .command)].joined()
                )
        )
    }

    @Test(
        "system actions use macOS's default keyboard shortcuts",
        arguments: [
            (SystemAction.missionControl, UInt16(0x7E), KeyModifiers.control),
            (.appExpose, 0x7D, .control), (.showDesktop, 0x67, KeyModifiers()), (.launchpad, 0x76, KeyModifiers()),
            (.previousSpace, 0x7B, .control), (.nextSpace, 0x7C, .control),
        ]
    )
    func systemActions(action: SystemAction, key: UInt16, modifiers: KeyModifiers) {
        #expect(SyntheticEventPlanner.plan(.perform(.system(action))).events == Self.stroke(key, modifiers))
    }

    @Test("screenshots map to the four macOS screenshot shortcuts")
    func screenshots() {
        let regionClip = ScreenshotAction(area: .region, destination: .clipboard)
        let fullFile = ScreenshotAction(area: .fullScreen, destination: .file)
        #expect(
            SyntheticEventPlanner.plan(.perform(.system(.screenshot(regionClip)))).events
                == Self.stroke(0x15, [.command, .shift, .control])
        )
        #expect(
            SyntheticEventPlanner.plan(.perform(.system(.screenshot(fullFile)))).events
                == Self.stroke(0x14, [.command, .shift])
        )
    }

    @Test(
        "media actions become paired media-key events with NX key codes",
        arguments: [
            (MediaAction.volumeUp, MediaKey.volumeUp, 0), (.volumeDown, .volumeDown, 1), (.mute, .mute, 7),
            (.playPause, .playPause, 16), (.nextTrack, .nextTrack, 17), (.previousTrack, .previousTrack, 18),
        ]
    )
    func media(action: MediaAction, key: MediaKey, raw: Int) {
        #expect(key.rawValue == raw)
        #expect(
            SyntheticEventPlanner.plan(.perform(.media(action))).events == [
                .mediaKey(key, isDown: true), .mediaKey(key, isDown: false),
            ]
        )
    }

    @Test("device actions and cycling Spaces are reported as not performable, never faked")
    func gaps() {
        #expect(
            SyntheticEventPlanner.plan(.perform(.device(.cycleResolutionPresets))).gap
                == .requiresDeviceConfiguration(.cycleResolutionPresets)
        )
        #expect(SyntheticEventPlanner.plan(.perform(.system(.cycleSpaces))).gap == .requiresPrivateAPI)
        #expect(SyntheticEventPlanner.plan(.perform(.device(.toggleSmartShift))).events.isEmpty)
    }

    @Test("every key down in every plan is followed by its key up")
    func keysNeverStayDown() {
        let actions: [Action] =
            ShortcutPreset.allCases.map(Action.shortcut) + MediaAction.allCases.map(Action.media)
            + [.system(.missionControl), .system(.launchpad), .click(.middle)]
        for action in actions {
            var down: [String: Int] = [:]
            for event in SyntheticEventPlanner.plan(.perform(action)).events {
                switch event {
                case .key(let key, let isDown, _): down["k\(key.rawValue)", default: 0] += isDown ? 1 : -1
                case .mediaKey(let key, let isDown): down["m\(key.rawValue)", default: 0] += isDown ? 1 : -1
                case .mouseButton(let button, let isDown): down["b\(button.rawValue)", default: 0] += isDown ? 1 : -1
                case .openApplication: break
                }
            }
            #expect(down.values.allSatisfy { $0 == 0 }, "\(action)")
        }
    }
}

final class RecordingPoster: SyntheticEventPosting, @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let lock = NSLock()
    private var log: [SyntheticEventSpec] = []
    var posted: [SyntheticEventSpec] { lock.withLock { log } }
    func post(_ spec: SyntheticEventSpec) { lock.withLock { log.append(spec) } }
}

@Suite("SyntheticInputExecutor")
struct SyntheticInputExecutorTests {
    @Test("tracks held buttons and drops unbalanced transitions")
    func balance() {
        let poster = RecordingPoster()
        let executor = SyntheticInputExecutor(poster: poster)

        executor.perform([.releaseSynthetic(.middle), .pressSynthetic(.middle), .pressSynthetic(.middle)])
        #expect(executor.heldButtons == [.middle])
        executor.perform([.releaseSynthetic(.middle), .releaseSynthetic(.middle)])

        #expect(poster.posted == [.mouseButton(.middle, isDown: true), .mouseButton(.middle, isDown: false)])
        #expect(executor.heldButtons.isEmpty)
    }

    @Test("releaseAllHeld releases every held button once")
    func releaseAll() {
        let poster = RecordingPoster()
        let executor = SyntheticInputExecutor(poster: poster)
        executor.perform([.pressSynthetic(.back), .pressSynthetic(.middle)])

        executor.releaseAllHeld()
        executor.releaseAllHeld()

        let releases: Set<SyntheticEventSpec> = [
            .mouseButton(.back, isDown: false), .mouseButton(.middle, isDown: false),
        ]
        #expect(poster.posted.filter(releases.contains).count == 2)
        #expect(executor.heldButtons.isEmpty)
    }

    @Test("rapid bursts stay balanced")
    func rapidBurst() {
        let poster = RecordingPoster()
        let executor = SyntheticInputExecutor(poster: poster)
        for _ in 0..<5_000 {
            executor.perform([.pressSynthetic(.middle), .releaseSynthetic(.middle), .perform(.click(.back))])
        }
        let downs = poster.posted.filter { if case .mouseButton(_, true) = $0 { true } else { false } }.count
        let ups = poster.posted.filter { if case .mouseButton(_, false) = $0 { true } else { false } }.count
        #expect(downs == 10_000 && ups == 10_000)
        #expect(executor.heldButtons.isEmpty)
    }

    @Test("commands that cannot be performed are counted, not posted")
    func gapsCounted() {
        let poster = RecordingPoster()
        let executor = SyntheticInputExecutor(poster: poster)
        executor.perform([.perform(.device(.toggleScrollMode)), .perform(.system(.cycleSpaces))])
        #expect(poster.posted.isEmpty)
        #expect(executor.unperformedCommands == 2)
    }
}

@Suite("CoreGraphicsEventPoster key flags")
struct CoreGraphicsEventPosterKeyFlagsTests {
    private static func key(_ raw: UInt16) -> KeyCode {
        guard let key = KeyCode(rawValue: raw) else { preconditionFailure("valid") }
        return key
    }

    @Test("arrow keys carry Fn and numeric pad, as a physical press does (⌃↑ is Mission Control)")
    func arrows() {
        for raw: UInt16 in [0x7B, 0x7C, 0x7D, 0x7E] {
            #expect(CoreGraphicsEventPoster.keyFlags(Self.key(raw)) == [.maskSecondaryFn, .maskNumericPad])
        }
    }

    @Test("function keys carry Fn (F11 is Show Desktop, F4 Launchpad); letters carry nothing")
    func functionKeysAndLetters() {
        #expect(CoreGraphicsEventPoster.keyFlags(Self.key(0x67)) == .maskSecondaryFn)
        #expect(CoreGraphicsEventPoster.keyFlags(Self.key(0x76)) == .maskSecondaryFn)
        #expect(CoreGraphicsEventPoster.keyFlags(Self.key(0x00)).isEmpty)
    }
}
