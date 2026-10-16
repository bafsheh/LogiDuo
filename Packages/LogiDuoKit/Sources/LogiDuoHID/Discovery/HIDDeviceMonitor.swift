import Foundation
public import IOKit.hid
public import LogiDuoDomain
public import LogiDuoHIDPP

/// A change in the set of Logitech HID interfaces.
public enum HIDDiscoveryEvent: Hashable, Sendable {
    /// An interface appeared (or was present when monitoring started).
    case added(HIDInterfaceDescriptor)
    /// The interface with this registry identifier disappeared.
    case removed(registryID: UInt64)
}

/// Watches Logitech HID interfaces with `IOHIDManager`, read-only.
///
/// Matching never opens a device. ``openTransport(registryID:framing:)``
/// opens one on request. Callbacks run on a private serial queue and only
/// translate IOKit objects into ``HIDDiscoveryEvent`` values.
///
/// **Ownership.** The manager is scheduled on the queue, activated once and
/// cancelled once; its cancel handler closes it and releases the callback
/// context, as IOKit requires. Device references are kept only while the
/// device is present, on the callback queue.
public final class HIDDeviceMonitor: @unchecked Sendable {  // Invariant: `devices` touched only on `queue`.
    /// Discovery events, starting with every interface present at activation.
    public let events: AsyncStream<HIDDiscoveryEvent>

    private final class Context: @unchecked Sendable {  // Invariant: accessed only on the monitor queue.
        let sink: AsyncStream<HIDDiscoveryEvent>.Continuation
        var devices: [UInt64: IOHIDDevice] = [:]

        init(sink: AsyncStream<HIDDiscoveryEvent>.Continuation) {
            self.sink = sink
        }
    }

    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "io.github.bafsheh.LogiDuo.hid.discovery")
    private let context: Context
    private let lock = NSLock()
    private var cancelled = false

    /// Starts monitoring HID interfaces of `vendor` (Logitech by default).
    public init(vendor: VendorID = .logitech) {
        let (events, sink) = AsyncStream.makeStream(of: HIDDiscoveryEvent.self, bufferingPolicy: .unbounded)
        self.events = events
        self.context = Context(sink: sink)
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching = Self.matching(vendor)
        IOHIDManagerSetDeviceMatching(manager, matching)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matched, opaque)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removed, opaque)
        IOHIDManagerSetDispatchQueue(manager, queue)
        let manager = self.manager
        IOHIDManagerSetCancelHandler(manager) {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            let context = Unmanaged<Context>.fromOpaque(opaque).takeRetainedValue()
            context.devices = [:]
            context.sink.finish()
        }
        IOHIDManagerActivate(manager)
    }

    deinit {
        stop()
    }

    /// Stops monitoring; ``events`` finishes once IOKit has released the manager's resources.
    public func stop() {
        let shouldCancel = lock.withLock {
            defer { cancelled = true }
            return !cancelled
        }
        if shouldCancel {
            IOHIDManagerCancel(manager)
        }
    }

    /// The interfaces of `vendor` present right now, read synchronously without opening anything.
    public static func snapshot(vendor: VendorID = .logitech) -> [HIDInterfaceDescriptor] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching(vendor))
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.map(HIDPropertyReader.descriptor(of:)).sorted { $0.registryID < $1.registryID }
    }

    /// Opens a HID++ transport to an interface found by ``snapshot(vendor:)``, without a running monitor.
    /// - Throws: ``HIDPPTransportError/disconnected`` if the interface is gone.
    public static func openSnapshotTransport(
        registryID: UInt64,
        framing: HIDPPFraming,
        vendor: VendorID = .logitech
    ) throws(HIDPPTransportError) -> IOKitHIDTransport {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching(vendor))
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard let device = devices.first(where: { HIDPropertyReader.registryID(of: $0) == registryID }) else {
            throw .disconnected
        }
        return try IOKitHIDTransport(device: device, framing: framing)
    }

    private static func matching(_ vendor: VendorID) -> CFDictionary {
        [kIOHIDVendorIDKey: Int(vendor.rawValue)] as CFDictionary
    }

    /// Opens a HID++ transport to a present interface.
    /// - Throws: ``HIDPPTransportError/disconnected`` if the interface is gone.
    public func openTransport(
        registryID: UInt64,
        framing: HIDPPFraming
    ) throws(HIDPPTransportError) -> IOKitHIDTransport {
        let context = self.context
        let device = queue.sync { context.devices[registryID].map(SendableDevice.init) }
        guard let device else { throw .disconnected }
        return try IOKitHIDTransport(device: device.device, framing: framing)
    }

    private struct SendableDevice: @unchecked Sendable {  // Invariant: CF reference, handed off once.
        let device: IOHIDDevice
    }

    // MARK: - C callbacks (on `queue`)

    private static let matched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        let descriptor = HIDPropertyReader.descriptor(of: device)
        box.devices[descriptor.registryID] = device
        box.sink.yield(.added(descriptor))
    }

    private static let removed: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        let registryID = HIDPropertyReader.registryID(of: device)
        box.devices[registryID] = nil
        box.sink.yield(.removed(registryID: registryID))
    }
}

/// Reads HID properties into plain values.
enum HIDPropertyReader {
    static func descriptor(of device: IOHIDDevice) -> HIDInterfaceDescriptor {
        let vendor = UInt16(truncatingIfNeeded: int(device, kIOHIDVendorIDKey) ?? 0)
        let product = UInt16(truncatingIfNeeded: int(device, kIOHIDProductIDKey) ?? 0)
        let transport = string(device, kIOHIDTransportKey)
        let serial = string(device, kIOHIDSerialNumberKey)
        let location = int(device, kIOHIDLocationIDKey)
        let fingerprintSource =
            serial.map { ["serial", transport ?? "", $0] }
            ?? location.map { ["location", transport ?? "", String($0)] }
        return HIDInterfaceDescriptor(
            registryID: registryID(of: device),
            hardware: HardwareIdentifier(vendor: VendorID(rawValue: vendor), product: ProductID(rawValue: product)),
            productName: string(device, kIOHIDProductKey),
            transport: transport,
            usages: usages(of: device),
            maximumInputReportSize: int(device, kIOHIDMaxInputReportSizeKey) ?? 0,
            maximumOutputReportSize: int(device, kIOHIDMaxOutputReportSizeKey) ?? 0,
            linkFingerprint: fingerprintSource.map(LinkFingerprint.make)
        )
    }

    static func registryID(of device: IOHIDDevice) -> UInt64 {
        var identifier: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &identifier)
        return identifier
    }

    private static func usages(of device: IOHIDDevice) -> [HIDUsage] {
        guard let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]
        else {
            return []
        }
        return pairs.compactMap { pair in
            guard
                let page = pair[kIOHIDDeviceUsagePageKey] as? Int,
                let usage = pair[kIOHIDDeviceUsageKey] as? Int
            else { return nil }
            return HIDUsage(page: UInt32(truncatingIfNeeded: page), usage: UInt32(truncatingIfNeeded: usage))
        }
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
