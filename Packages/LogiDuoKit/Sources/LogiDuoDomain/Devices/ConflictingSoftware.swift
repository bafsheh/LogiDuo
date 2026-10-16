/// Other software that also configures Logitech devices and may override LogiDuo.
public enum ConflictingSoftware: String, CaseIterable, Hashable, Sendable {
    case logiOptionsPlus
    case logitechOptions
    case gHub
    case mouser

    /// Classifies a running application by bundle identifier and name; `nil` if unrelated.
    public static func classify(bundleIdentifier: String?, name: String?) -> ConflictingSoftware? {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        if bundle.hasPrefix("com.logi.") || bundle.hasPrefix("com.logitech.") {
            if bundle.contains("optionsplus") { return .logiOptionsPlus }
            if bundle.contains("ghub") { return .gHub }
            if bundle.contains("options") || bundle.contains("manager") { return .logitechOptions }
        }
        if name?.lowercased() == "mouser" || bundle.contains("mouser") { return .mouser }
        return nil
    }
}
