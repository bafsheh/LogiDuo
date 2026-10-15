public import LogiDuoDomain

extension DeviceID {
    /// Deterministic identifiers for tests.
    public static func fixture(_ index: Int) -> DeviceID {
        guard let id = DeviceID(rawValue: "test-device-\(index)") else {
            preconditionFailure("fixture identifiers are never empty")
        }
        return id
    }
}
