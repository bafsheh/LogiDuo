import LogiDuoDomain
import LogiDuoFeatures
import LogiDuoTestSupport
import Testing

@MainActor
@Suite("AppRouter")
struct AppRouterTests {
    @Test("starts on the device list with nothing selected by default")
    func defaultRoute() {
        let router = AppRouter()

        #expect(router.currentRoute == .devices(selected: nil))
    }

    @Test(
        "honours the initial route",
        arguments: [
            AppRoute.profiles,
            .permissions,
            .devices(selected: .fixture(1)),
        ]
    )
    func initialRoute(route: AppRoute) {
        #expect(AppRouter(initialRoute: route).currentRoute == route)
    }

    @Test("show replaces the device selection carried by the route")
    func showReplacesSelection() {
        let router = AppRouter(initialRoute: .devices(selected: .fixture(1)))

        router.show(.devices(selected: .fixture(2)))
        #expect(router.currentRoute == .devices(selected: .fixture(2)))

        router.show(.devices(selected: nil))
        #expect(router.currentRoute == .devices(selected: nil))
    }

    @Test("show to a non-device route keeps the device selection for later")
    func showOtherRouteKeepsSelection() {
        let router = AppRouter(initialRoute: .devices(selected: .fixture(1)))

        router.show(.permissions)
        #expect(router.destination == .permissions)
        #expect(router.selectedDevice == .fixture(1))
    }

    @Test("device selection is preserved while visiting other destinations")
    func selectionSurvivesSidebarChanges() {
        let router = AppRouter()
        router.selectDevice(.fixture(1))

        router.select(.profiles)
        #expect(router.currentRoute == .profiles)

        router.select(.devices)
        #expect(router.currentRoute == .devices(selected: .fixture(1)))
    }

    @Test("selecting a device switches to the device list")
    func selectingDeviceSwitchesDestination() {
        let router = AppRouter(initialRoute: .permissions)

        router.selectDevice(.fixture(3))

        #expect(router.currentRoute == .devices(selected: .fixture(3)))
    }

    @Test("reconcile drops a selection for a device that disappeared")
    func reconcileDropsUnknownDevice() {
        let router = AppRouter(initialRoute: .devices(selected: .fixture(1)))

        router.reconcile(knownDevices: [.fixture(2)])

        #expect(router.selectedDevice == nil)
    }

    @Test("reconcile keeps a selection for a device that is still known")
    func reconcileKeepsKnownDevice() {
        let router = AppRouter(initialRoute: .devices(selected: .fixture(1)))

        router.reconcile(knownDevices: [.fixture(1), .fixture(2)])

        #expect(router.selectedDevice == .fixture(1))
    }
}
