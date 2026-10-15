public import LogiDuoDomain

extension DeviceID {
    /// Deterministic identifiers for tests.
    public static func fixture(_ index: Int) -> DeviceID {
        DeviceID(rawValue: "test-device-\(index)")
    }
}
