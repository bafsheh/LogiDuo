import LogiDuoDomain
import LogiDuoHIDPP
import Testing

@testable import LogiDuoHID

@Suite("HIDInterfaceClassifier")
struct HIDInterfaceClassifierTests {
    private static func descriptor(
        vendor: UInt16 = 0x046D,
        product: UInt16,
        transport: String?,
        usages: [(UInt32, UInt32)],
        output: Int = 20
    ) -> HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(
            registryID: 1,
            hardware: HardwareIdentifier(vendor: VendorID(rawValue: vendor), product: ProductID(rawValue: product)),
            productName: nil,
            transport: transport,
            usages: usages.map { HIDUsage(page: $0.0, usage: $0.1) },
            maximumInputReportSize: 20,
            maximumOutputReportSize: output,
            linkFingerprint: nil
        )
    }

    @Test("MX Master 3S over Bluetooth LE (as reported by ioreg) is a long-only direct device")
    func mxMaster3S() {
        let mouse = Self.descriptor(
            product: 0xB034,
            transport: "Bluetooth Low Energy",
            usages: [(0x1, 0x2), (0x1, 0x1), (0xFF43, 0x202)]
        )
        #expect(HIDInterfaceClassifier.role(of: mouse) == .directDevice(.bluetoothLowEnergy, .bluetoothLowEnergy))
    }

    @Test("MX Keys over Bluetooth LE is a direct device even though it also declares keyboard usages")
    func mxKeys() {
        let keyboard = Self.descriptor(
            product: 0xB35B,
            transport: "Bluetooth Low Energy",
            usages: [(0x1, 0x6), (0x1, 0x2), (0x1, 0x1), (0xC, 0x1), (0xFF43, 0x202)]
        )
        #expect(HIDInterfaceClassifier.role(of: keyboard) == .directDevice(.bluetoothLowEnergy, .bluetoothLowEnergy))
    }

    @Test("a Bolt receiver's HID++ interface is a receiver with short and long output")
    func boltReceiver() {
        let receiver = Self.descriptor(product: 0xC548, transport: "USB", usages: [(0xFF00, 0x1), (0xFF00, 0x2)])
        #expect(HIDInterfaceClassifier.role(of: receiver) == .receiver(.bolt, .receiver))
    }

    @Test("a receiver's keyboard or mouse interface is never treated as writable")
    func receiverInputInterface() {
        let input = Self.descriptor(product: 0xC548, transport: "USB", usages: [(0x1, 0x6)])
        let role = HIDInterfaceClassifier.role(of: input)
        #expect(role == .logitechWithoutHIDPP)
        #expect(!role.acceptsHIDPP)
    }

    @Test("a short-only vendor collection is not a HID++ 2.0 endpoint")
    func shortOnly() {
        let shortOnly = Self.descriptor(product: 0xC52B, transport: "USB", usages: [(0xFF00, 0x1)])
        #expect(HIDInterfaceClassifier.role(of: shortOnly) == .logitechWithoutHIDPP)
    }

    @Test("an interface whose output reports cannot hold a long report is rejected")
    func outputTooSmall() {
        let small = Self.descriptor(
            product: 0xB034,
            transport: "Bluetooth Low Energy",
            usages: [(0xFF43, 0x202)],
            output: 7
        )
        #expect(HIDInterfaceClassifier.role(of: small) == .logitechWithoutHIDPP)
    }

    @Test("non-Logitech interfaces are unrelated, whatever they declare")
    func otherVendor() {
        let other = Self.descriptor(vendor: 0x05AC, product: 0x0265, transport: "USB", usages: [(0xFF00, 0x2)])
        #expect(HIDInterfaceClassifier.role(of: other) == .unrelated)
    }

    @Test("unknown receivers are direct devices of their link; wired devices get short output when declared")
    func wiredDevice() {
        let wired = Self.descriptor(product: 0xC08B, transport: "USB", usages: [(0xFF00, 0x1), (0xFF00, 0x2)])
        #expect(HIDInterfaceClassifier.role(of: wired) == .directDevice(.usbWired, .receiver))
    }

    @Test(
        "transport strings map to links",
        arguments: [
            ("Bluetooth Low Energy", DirectLink.bluetoothLowEnergy), ("Bluetooth", .bluetoothClassic),
            ("USB", .usbWired), ("SPI", .usbWired),
        ]
    )
    func links(transport: String, expected: DirectLink) {
        #expect(HIDInterfaceClassifier.directLink(for: transport) == expected)
    }

    @Test("link fingerprints are stable and never contain the raw value")
    func fingerprints() {
        let address = "AA-BB-CC-DD-EE-FF"
        let first = LinkFingerprint.make(["serial", "Bluetooth Low Energy", address])
        let second = LinkFingerprint.make(["serial", "Bluetooth Low Energy", address])
        let other = LinkFingerprint.make(["serial", "Bluetooth Low Energy", "AA-BB-CC-DD-EE-00"])

        #expect(first == second)
        #expect(first != other)
        #expect(!first.contains("AA-BB"))
    }
}
