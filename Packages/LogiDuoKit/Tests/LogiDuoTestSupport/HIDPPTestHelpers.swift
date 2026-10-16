/// Helpers for building HID++ traffic in tests.
public enum HIDPPTestTraffic {
    /// A reply that echoes the header of `request` (device, feature, function, software ID).
    public static func reply(to request: [UInt8], parameters: [UInt8] = []) -> [UInt8] {
        Array(request.prefix(4)) + parameters + Array(repeating: 0, count: 16 - parameters.count)
    }

    /// A HID++ 2.0 error report for `request`.
    public static func featureError(for request: [UInt8], code: UInt8) -> [UInt8] {
        [0x11, request[1], 0xFF, request[2], request[3], code] + Array(repeating: 0, count: 14)
    }

    /// A HID++ 1.0 error report (0x8F) for `request`.
    public static func legacyError(for request: [UInt8], code: UInt8) -> [UInt8] {
        [0x10, request[1], 0x8F, request[2], request[3], code, 0x00]
    }

    /// A HID++ 2.0 notification (software ID 0).
    public static func notification(
        device: UInt8 = 0xFF,
        feature: UInt8,
        function: UInt8,
        parameters: [UInt8] = []
    )
        -> [UInt8]
    {
        [0x11, device, feature, function << 4] + parameters + Array(repeating: 0, count: 16 - parameters.count)
    }
}

/// Yields until `condition` holds, failing after a bounded number of attempts.
///
/// Used instead of sleeping when a test must wait for another task to reach
/// a known state (for example, a request being queued).
public func eventually(
    _ attempts: Int = 10_000,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
