import Foundation
import LogiDuoDomain
import Testing

@Suite("DeviceID")
struct DeviceIDTests {
    @Test("description never reveals the raw identity")
    func descriptionIsRedacted() {
        let serialLike = "4B1A-99C2-SERIAL"
        let id = DeviceID(rawValue: serialLike)

        #expect(!id.description.contains(serialLike))
        #expect(!"\(id)".contains("SERIAL"))
    }

    @Test("round-trips through Codable as a bare string")
    func codableRoundTrip() throws {
        let id = DeviceID(rawValue: "abc")

        let data = try JSONEncoder().encode(id)
        #expect(String(bytes: data, encoding: .utf8) == "\"abc\"")
        #expect(try JSONDecoder().decode(DeviceID.self, from: data) == id)
    }
}
