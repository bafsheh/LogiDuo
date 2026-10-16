public import IOKit
public import LogiDuoHIDPP

extension HIDPPTransportError {
    /// `kIOReturnNotPermitted`: macOS refused access (for example Input Monitoring is not granted).
    static let notPermitted: IOReturn = IOReturn(bitPattern: 0xE000_02E2)
    /// `kIOReturnNotPrivileged`.
    static let notPrivileged: IOReturn = IOReturn(bitPattern: 0xE000_02C1)
    /// `kIOReturnNoDevice`.
    static let noDevice: IOReturn = IOReturn(bitPattern: 0xE000_02C0)
    /// `kIOReturnNotAttached`.
    static let notAttached: IOReturn = IOReturn(bitPattern: 0xE000_02D9)
    /// `kIOReturnAborted`.
    static let aborted: IOReturn = IOReturn(bitPattern: 0xE000_02EB)

    /// Maps a failing `IOReturn` to a transport error.
    public init(ioReturn: IOReturn) {
        switch ioReturn {
        case Self.notPermitted, Self.notPrivileged: self = .accessDenied
        case Self.noDevice, Self.notAttached, Self.aborted: self = .disconnected
        default: self = .ioFailure(code: ioReturn)
        }
    }
}
