import IOKit
import LogiDuoHID
import LogiDuoHIDPP
import Testing

@Suite("IOReturn mapping")
struct IOReturnMappingTests {
    @Test(
        "permission failures map to access denied, which is not recoverable",
        arguments: [
            IOReturn(bitPattern: 0xE000_02E2), IOReturn(bitPattern: 0xE000_02C1),
        ]
    )
    func accessDenied(code: IOReturn) {
        let error = HIDPPTransportError(ioReturn: code)
        #expect(error == .accessDenied)
        #expect(!error.isRecoverable)
    }

    @Test(
        "a vanished device maps to disconnected",
        arguments: [
            IOReturn(bitPattern: 0xE000_02C0), IOReturn(bitPattern: 0xE000_02D9), IOReturn(bitPattern: 0xE000_02EB),
        ]
    )
    func disconnected(code: IOReturn) {
        #expect(HIDPPTransportError(ioReturn: code) == .disconnected)
    }

    @Test("other failures keep their code and are recoverable")
    func otherFailures() {
        let busy = IOReturn(bitPattern: 0xE000_02D5)
        #expect(HIDPPTransportError(ioReturn: busy) == .ioFailure(code: busy))
        #expect(HIDPPTransportError(ioReturn: busy).isRecoverable)
        #expect(HIDPPTransportError(ioReturn: kIOReturnExclusiveAccess) == .ioFailure(code: kIOReturnExclusiveAccess))
    }
}
