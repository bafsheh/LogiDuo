import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("Hardware and transport identifiers")
struct HardwareIdentifierTests {
    @Test("formats vendor and product identifiers as zero-padded hexadecimal")
    func hexFormatting() {
        let hardware = HardwareIdentifier(vendor: .logitech, product: ProductID(rawValue: 0x0A1))
        #expect(hardware.description == "0x046D:0x00A1")
        #expect(hardware.isLogitech)
        #expect(!HardwareIdentifier(vendor: VendorID(rawValue: 0x05AC), product: ProductID(rawValue: 1)).isLogitech)
    }

    @Test(
        "classifies only receivers with verified product identifiers",
        arguments: [
            (UInt16(0xC548), ReceiverKind.bolt),
            (0xC52B, .unifying),
            (0xC534, .unknown),
            (0xB034, .unknown),
        ]
    )
    func receiverClassification(product: UInt16, expected: ReceiverKind) {
        #expect(ReceiverKind(product: ProductID(rawValue: product)) == expected)
    }

    @Test("accepts receiver slots 1 through 6 only", arguments: UInt8(0)...UInt8(8))
    func slotValidation(number: UInt8) {
        #expect((ReceiverSlot(rawValue: number) != nil) == (1...6).contains(number))
    }

    @Test("rejects the direct-connection device index as a slot")
    func directIndexIsNotASlot() {
        #expect(ReceiverSlot(rawValue: 0xFF) == nil)
    }

    @Test("rejects empty or blank opaque identifiers", arguments: ["", " ", "\n\t"])
    func blankIdentifiersRejected(value: String) {
        #expect(DeviceID(rawValue: value) == nil)
        #expect(ReceiverID(rawValue: value) == nil)
        #expect(EndpointKey(rawValue: value) == nil)
    }

    @Test("rejects model identifiers wider than 48 bits")
    func modelIDWidth() {
        #expect(ModelID(rawValue: 0xFFFF_FFFF_FFFF) != nil)
        #expect(ModelID(rawValue: 0x1_0000_0000_0000) == nil)
    }

    @Test("trims model names and rejects blank ones")
    func modelNameValidation() {
        let model = DeviceModel(name: "  MX Keys \n", product: ProductID(rawValue: 0xB35B), category: .keyboard)
        #expect(model?.name == "MX Keys")
        #expect(DeviceModel(name: "   ", product: ProductID(rawValue: 1), category: .mouse) == nil)
    }

    @Test("descriptions of identity values never reveal raw identifiers")
    func redaction() throws {
        let receiver = try #require(ReceiverID(rawValue: "SERIAL-1234"))
        let key = try #require(EndpointKey(rawValue: "SERIAL-5678"))
        let physical = IdentityFixtures.physical(unit: 0xDEAD_BEEF)

        #expect(!receiver.description.contains("SERIAL"))
        #expect(!key.description.contains("SERIAL"))
        #expect(!physical.description.contains("DEADBEEF"))
        #expect(!UnitID(rawValue: 0xDEAD_BEEF).description.contains("DEADBEEF"))
    }

    @Test("derives the transport type from the endpoint")
    func transportType() {
        #expect(IdentityFixtures.bluetooth().transportType == .bluetoothLowEnergy)
        let bolt = TransportEndpoint.receiver(IdentityFixtures.boltReceiver(), IdentityFixtures.slot(2))
        #expect(bolt.transportType == .receiver(.bolt))
        #expect(bolt.receiver == IdentityFixtures.boltReceiver())
        #expect(IdentityFixtures.bluetooth().receiver == nil)
    }
}
