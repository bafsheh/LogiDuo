import LogiDuoFeatures
import Testing

@testable import LogiDuo

@MainActor
@Suite("AppCompositionRoot")
struct AppCompositionRootTests {
    @Test("wires a router that opens on the device list and remapping that starts off")
    func defaultGraph() {
        let root = AppCompositionRoot()

        #expect(root.router.currentRoute == .devices(selected: nil))
        #expect(root.remapping.status == .off)
        #expect(!root.remappingModel.isEnabled)
    }

    @Test("uses the injected router instance")
    func injectedRouter() {
        let router = AppRouter(initialRoute: .permissions)

        #expect(AppCompositionRoot(router: router).router === router)
    }
}
