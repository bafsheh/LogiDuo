import CoreGraphics
import Foundation
import LogiDuoDomain
import LogiDuoSystem
import Testing

/// Whether live-system tests (real event taps in this login session) were requested.
let systemTestsEnabled = ProcessInfo.processInfo.environment["LOGIDUO_SYSTEM"] == "1"

/// Parent of every live-system suite. `.serialized` applies to all nested suites, so
/// only one sink and one engine are ever active at a time: concurrent sinks would
/// swallow each other's test events.
@Suite("System (live event pipeline)", .enabled(if: systemTestsEnabled), .serialized)
enum LiveSystemSuites {}

/// Marks events injected by system tests (`'TEST'`), distinct from LogiDuo's own marker.
let testInjectionMarker: Int64 = 0x5445_5354

/// A recorded event that reached the end of the event pipeline.
struct SinkRecord: Hashable, Sendable {
    let type: UInt32
    let button: Int64
    let keyCode: Int64
    let userData: Int64
    let flags: UInt64
}

/// A tail tap just before event delivery to applications. It records and swallows
/// every event carrying the test or LogiDuo marker, so system tests never reach apps.
/// Unmarked (real user) events pass untouched.
final class EventSink: @unchecked Sendable {  // Invariant: `records` guarded by `condition`.
    private let condition = NSCondition()
    private var records: [SinkRecord] = []
    private let backend = SinkBackend()

    /// Starts the sink. Returns `false` if the tap could not be created.
    func start() -> Bool {
        backend.install { [weak self] type, event in
            let userData = event.getIntegerValueField(.eventSourceUserData)
            guard userData == testInjectionMarker || SyntheticEventMarker.isLogiDuoEvent(userData: userData) else {
                return event
            }
            self?.append(
                SinkRecord(
                    type: type.rawValue,
                    button: event.getIntegerValueField(.mouseEventButtonNumber),
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    userData: userData,
                    flags: event.flags.rawValue
                )
            )
            return nil
        }
    }

    func stop() { backend.remove() }

    var all: [SinkRecord] { condition.withLock { records } }

    func clear() { condition.withLock { records = [] } }

    private func append(_ record: SinkRecord) {
        condition.withLock {
            records.append(record)
            condition.broadcast()
        }
    }

    /// Waits until `predicate` holds for the recorded events; `timeout` only bounds a failing wait.
    func wait(timeout: TimeInterval = 2, until predicate: ([SinkRecord]) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(records) {
            guard condition.wait(until: deadline) else { return predicate(records) }
        }
        return true
    }
}

/// Installs a tail tap at the annotated-session location (after LogiDuo's session tap).
final class SinkBackend: @unchecked Sendable {  // Invariant: guarded by `lock`.
    private let inner = TailTap()
    func install(_ handler: @escaping EventTapHandler) -> Bool { inner.install(handler) }
    func remove() { inner.remove() }
}

/// Minimal tail tap on its own run-loop thread (test-only; mirrors the production backend's ownership).
final class TailTap: @unchecked Sendable {  // Invariant: guarded by `lock`.
    private final class Box: @unchecked Sendable {  // Invariant: immutable after init.
        let handler: EventTapHandler
        init(_ handler: @escaping EventTapHandler) { self.handler = handler }
    }

    private final class Handoff: @unchecked Sendable {  // Invariant: `loop` written before `started` signals.
        let port: CFMachPort
        let source: CFRunLoopSource
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        init(port: CFMachPort, source: CFRunLoopSource) {
            self.port = port
            self.source = source
        }
    }

    private let lock = NSLock()
    private var state: (Handoff, Unmanaged<Box>)?

    static let mask: CGEventMask = [
        CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ].reduce(CGEventMask(1) << 14) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }

    func install(_ handler: @escaping EventTapHandler) -> Bool {
        let box = Unmanaged.passRetained(Box(handler))
        guard
            let port = CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap,
                place: .tailAppendEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.mask,
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                    return box.handler(type, event).map { Unmanaged.passUnretained($0) }
                },
                userInfo: box.toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            box.release()
            return false
        }
        let handoff = Handoff(port: port, source: source)
        Thread {
            handoff.loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), handoff.source, .commonModes)
            CGEvent.tapEnable(tap: handoff.port, enable: true)
            handoff.started.signal()
            CFRunLoopRun()
            handoff.finished.signal()
        }.start()
        handoff.started.wait()
        lock.withLock { state = (handoff, box) }
        return true
    }

    func remove() {
        guard
            let (handoff, box) = lock.withLock({ () -> (Handoff, Unmanaged<Box>)? in
                defer { state = nil }
                return state
            })
        else { return }
        CGEvent.tapEnable(tap: handoff.port, enable: false)
        if let loop = handoff.loop {
            CFRunLoopRemoveSource(loop, handoff.source, .commonModes)
            CFMachPortInvalidate(handoff.port)
            CFRunLoopStop(loop)
            handoff.finished.wait()
        }
        box.release()
    }
}

/// Posts test-marked mouse events at the HID level, so they traverse LogiDuo's session tap like physical input.
enum Injector {
    static func button(_ type: CGEventType, number: Int64) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let cgButton: CGMouseButton = number == 0 ? .left : (number == 1 ? .right : .center)
        guard
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: cgButton
            )
        else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        event.setIntegerValueField(.eventSourceUserData, value: testInjectionMarker)
        event.post(tap: .cghidEventTap)
    }

    static func click(number: Int64) {
        let types: (CGEventType, CGEventType) =
            switch number {
            case 0: (.leftMouseDown, .leftMouseUp)
            case 1: (.rightMouseDown, .rightMouseUp)
            default: (.otherMouseDown, .otherMouseUp)
            }
        button(types.0, number: number)
        button(types.1, number: number)
    }
}
