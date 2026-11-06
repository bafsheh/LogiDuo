import SwiftUI

/// Strict blueprint palette — nothing outside this ink set.
enum BlueprintTheme {
    /// Deep plate / sheet field.
    static let plate = Color(red: 0.04, green: 0.16, blue: 0.30)
    /// Slightly lifted panel fill.
    static let panel = Color(red: 0.06, green: 0.22, blue: 0.38)
    /// Primary cyan ink.
    static let ink = Color(red: 0.55, green: 0.82, blue: 0.98)
    /// Dim construction ink.
    static let inkDim = ink.opacity(0.22)
    /// Mid emphasis.
    static let inkMid = ink.opacity(0.55)
    /// Bright selected / mapped mark.
    static let inkHot = Color(red: 0.78, green: 0.94, blue: 1.0)
}
