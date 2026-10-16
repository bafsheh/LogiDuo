import LogiDuoDomain
import LogiDuoSystem
import Testing

extension LiveSystemSuites {
    @Suite("System: permission status (read-only, never prompts)")
    struct SystemPermissionTests {
        @Test("reports the real status of both permissions")
        func realStatus() {
            let checker = SystemPermissionChecker()
            let accessibility = checker.status(of: .accessibility)
            let inputMonitoring = checker.status(of: .inputMonitoring)
            print("[system] accessibility=\(accessibility) inputMonitoring=\(inputMonitoring)")
            // The live-system suites need Accessibility; if they ran, it is granted.
            #expect(accessibility == .granted)
        }
    }
}
