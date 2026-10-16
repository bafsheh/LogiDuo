public import CoreGraphics
import Foundation

/// Handles one tapped event synchronously and returns the event to deliver, or `nil` to suppress it.
public typealias EventTapHandler = @Sendable (CGEventType, CGEvent) -> CGEvent?

/// Creates and controls the system event tap. Abstracted for failure injection in tests.
public protocol EventTapBackend: Sendable {
    /// Installs and enables a tap for `mask`, delivering events to `handler`.
    /// - Returns: `false` if macOS refused (usually: Accessibility not granted).
    func install(mask: CGEventMask, handler: @escaping EventTapHandler) -> Bool
    /// Re-enables a tap that macOS disabled.
    func reenable()
    /// Removes the tap. Idempotent; returns after the callback can no longer run.
    func remove()
    /// Whether a tap is currently installed.
    var isInstalled: Bool { get }
}

/// The mouse events LogiDuo taps: buttons other than primary/secondary, motion and scrolling.
///
/// Primary and secondary buttons and all keyboard events are deliberately absent.
public enum LogiDuoEventMask {
    /// The tap mask.
    public static let value: CGEventMask = [
        CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .scrollWheel,
    ].reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }
}

/// The real backend: an active session event tap on a dedicated run-loop thread.
///
/// **Ownership.** The handler box is retained once for the tap's `userInfo` and
/// released in ``remove()`` only after the tap is disabled, its source is
/// removed, the mach port is invalidated and the run-loop thread has exited —
/// so the callback can never see a released box.
public final class CoreGraphicsEventTapBackend: EventTapBackend, @unchecked Sendable {  // Invariant: `lock`.
    private final class HandlerBox: @unchecked Sendable {  // Invariant: immutable after init.
        let handler: EventTapHandler

        init(handler: @escaping EventTapHandler) {
            self.handler = handler
        }
    }

    /// Carries the tap's CF objects to the run-loop thread and its run loop back.
    private final class RunLoopHandoff: @unchecked Sendable {  // Invariant: `loop` set before `started`.
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

    private struct Installation {
        let port: CFMachPort
        let runLoop: CFRunLoop
        let source: CFRunLoopSource
        let box: Unmanaged<HandlerBox>
        let finished: DispatchSemaphore
    }

    private let lock = NSLock()
    private var installation: Installation?

    /// Creates a backend.
    public init() {}

    /// Whether a tap is installed.
    public var isInstalled: Bool { lock.withLock { installation != nil } }

    /// Installs the tap on a new run-loop thread.
    public func install(mask: CGEventMask, handler: @escaping EventTapHandler) -> Bool {
        remove()
        let box = Unmanaged.passRetained(HandlerBox(handler: handler))
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: box.toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            box.release()
            return false
        }
        let handoff = RunLoopHandoff(port: port, source: source)
        let thread = Thread {
            handoff.loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), handoff.source, .commonModes)
            CGEvent.tapEnable(tap: handoff.port, enable: true)
            handoff.started.signal()
            CFRunLoopRun()
            handoff.finished.signal()
        }
        thread.name = "io.github.bafsheh.LogiDuo.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        handoff.started.wait()
        guard let runLoop = handoff.loop else { return false }
        lock.withLock {
            installation = Installation(
                port: port,
                runLoop: runLoop,
                source: source,
                box: box,
                finished: handoff.finished
            )
        }
        return true
    }

    /// Re-enables the tap after macOS disabled it.
    public func reenable() {
        guard let port = lock.withLock({ installation?.port }) else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Disables and removes the tap, then releases the handler.
    ///
    /// Safe from any thread, including inside the tap callback (for example when the
    /// last owner is released there): on the tap's own thread it does not wait for
    /// that thread to finish, which would deadlock. A callback in progress keeps the
    /// handler box alive through its own strong reference.
    public func remove() {
        guard
            let removed = lock.withLock({ () -> Installation? in
                defer { installation = nil }
                return installation
            })
        else { return }
        let onTapThread = CFRunLoopGetCurrent() === removed.runLoop
        CGEvent.tapEnable(tap: removed.port, enable: false)
        CFRunLoopRemoveSource(removed.runLoop, removed.source, .commonModes)
        CFMachPortInvalidate(removed.port)
        CFRunLoopStop(removed.runLoop)
        if !onTapThread {
            removed.finished.wait()
        }
        removed.box.release()
    }

    deinit {
        remove()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let box = Unmanaged<HandlerBox>.fromOpaque(userInfo).takeUnretainedValue()
        guard let delivered = box.handler(type, event) else { return nil }
        return Unmanaged.passUnretained(delivered)
    }
}
