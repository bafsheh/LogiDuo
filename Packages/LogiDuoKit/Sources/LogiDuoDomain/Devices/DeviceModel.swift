import Foundation

/// What a connected device reports about its model.
public struct DeviceModel: Hashable, Sendable, Codable {
    /// The name reported by the device, trimmed; never empty.
    public let name: String
    /// The product identifier on the current transport. See ``ProductID``.
    public let product: ProductID
    /// The device category.
    public let category: DeviceCategory

    /// Creates a model description, rejecting empty or whitespace-only names.
    public init?(name: String, product: ProductID, category: DeviceCategory) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.name = trimmed
        self.product = product
        self.category = category
    }
}
