/// Formats `value` as upper-case hexadecimal, zero-padded to `digits`.
///
/// Used for identifiers and diagnostics so the domain does not depend on
/// `String(format:)`.
func hexString(_ value: some FixedWidthInteger & UnsignedInteger, digits: Int) -> String {
    let raw = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, digits - raw.count)) + raw
}
