/// Parses `"11 FF 00 0A …"` into bytes. A trailing `…` zero-pads to `padTo`.
func hexBytes(_ text: String, padTo length: Int = 20) -> [UInt8] {
    var bytes: [UInt8] = []
    var pad = false
    for token in text.split(separator: " ") {
        if token == "…" {
            pad = true
            continue
        }
        guard let byte = UInt8(token, radix: 16) else { preconditionFailure("bad hex token \(token)") }
        bytes.append(byte)
    }
    return pad ? bytes + Array(repeating: 0, count: max(0, length - bytes.count)) : bytes
}
