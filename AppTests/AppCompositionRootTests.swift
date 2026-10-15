import LogiDuoFeatures
import Testing

@testable import LogiDuo

@MainActor
@Suite("AppCompositionRoot")
struct AppCompositionRootTests {
    @Test("wires a router that opens on the device list")
    func defaultGraph() {
        let root = AppCompositionRoot()

        #expect(root.router.currentRoute == .devices(selected: nil))
    }

    @Test("uses the injected router instance")
    func injectedRouter() {
        let router = AppRouter(initialRoute: .permissions)

        #expect(AppCompositionRoot(router: router).router === router)
    }
}
