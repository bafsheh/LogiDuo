import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@testable import LogiDuoSystem

@Suite("ApplicationIdentityBuilder")
struct ApplicationIdentityBuilderTests {
    private static func executable(_ path: String) -> ApplicationMatcher {
        guard let path = ExecutablePath(path) else { preconditionFailure("absolute fixture path") }
        return .executablePath(path)
    }

    @Test("a helper inside an app also matches the enclosing app, innermost first, executable last")
    func nested() {
        let identity = ApplicationIdentityBuilder.identity(
            bundleIdentifier: "com.example.Helper",
            bundlePath: "/Applications/Example.app/Contents/Frameworks/Helper.app",
            executablePath: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        ) { path in
            [
                "/Applications/Example.app": "com.example.App",
                "/Applications/Example.app/Contents/Frameworks/Helper.app": "com.example.Helper",
            ][path]
        }
        #expect(
            identity.references == [
                ProfileFixtures.app("com.example.Helper"),
                ProfileFixtures.app("com.example.App"),
                Self.executable("/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            ]
        )
    }

    @Test("a bare executable is identified by its path")
    func executableOnly() {
        let identity = ApplicationIdentityBuilder.identity(
            bundleIdentifier: nil,
            bundlePath: nil,
            executablePath: "/usr/local/bin/tool"
        ) { _ in nil }
        #expect(identity.references == [Self.executable("/usr/local/bin/tool")])
    }

    @Test("enclosing bundles are listed innermost first")
    func enclosing() {
        #expect(
            ApplicationIdentityBuilder.enclosingBundles("/A.app/Contents/B.app/Contents/MacOS/b")
                == ["/A.app/Contents/B.app", "/A.app"]
        )
        #expect(ApplicationIdentityBuilder.enclosingBundles("relative/A.app").isEmpty)
    }
}
