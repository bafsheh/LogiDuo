import LogiDuoDomain
import LogiDuoTestSupport
import Testing

@Suite("DeviceIdentityRegistry")
struct DeviceIdentityRegistryTests {
    private typealias Fixture = IdentityFixtures

    private let boltSlot1 = TransportEndpoint.receiver(Fixture.boltReceiver(), Fixture.slot(1))
    private let boltSlot2 = TransportEndpoint.receiver(Fixture.boltReceiver(), Fixture.slot(2))

    @Test("registers an unknown device and reports the same identity again")
    func registerThenMatch() {
        var registry = DeviceIdentityRegistry()

        let first = registry.reconcile(Fixture.observation(Fixture.bluetooth()))
        let second = registry.reconcile(Fixture.observation(Fixture.bluetooth()))

        #expect(first.outcome == .registered)
        #expect(second.outcome == .matchedEndpoint)
        #expect(first.identity.id == second.identity.id)
        #expect(registry.count == 1)
    }

    @Test("keeps the identity when a device moves from a receiver to Bluetooth")
    func transportChangeKeepsIdentity() {
        var registry = DeviceIdentityRegistry()
        let physical = Fixture.physical(unit: 7)
        let viaBolt = registry.reconcile(
            Fixture.observation(
                boltSlot1,
                model: Fixture.mouse(product: Fixture.mxMaster3SReceiver),
                physical: physical
            )
        )

        let viaBluetooth = registry.reconcile(Fixture.observation(Fixture.bluetooth(), physical: physical))

        #expect(viaBluetooth.identity.id == viaBolt.identity.id)
        #expect(viaBluetooth.outcome == .matchedPhysicalIdentity(transportChanged: true))
        #expect(viaBluetooth.identity.endpoint == Fixture.bluetooth())
        #expect(viaBluetooth.identity.model.product == Fixture.mxMaster3SBluetooth)
    }

    @Test("does not merge devices that differ only by transport product identifier without firmware identity")
    func productIdentifiersAreNotIdentity() {
        var registry = DeviceIdentityRegistry()

        let viaBolt = registry.reconcile(
            Fixture.observation(boltSlot1, model: Fixture.mouse(product: Fixture.mxMaster3SReceiver))
        )
        let viaBluetooth = registry.reconcile(Fixture.observation(Fixture.bluetooth()))

        #expect(viaBolt.identity.id != viaBluetooth.identity.id)
        #expect(registry.count == 2)
    }

    @Test("gives every device sharing a receiver its own identity")
    func multipleDevicesOnOneReceiver() {
        var registry = DeviceIdentityRegistry()
        let mouse = registry.reconcile(Fixture.observation(boltSlot1, physical: Fixture.physical(unit: 1)))
        let keyboard = registry.reconcile(
            Fixture.observation(
                boltSlot2,
                model: DeviceModel(name: "MX Keys", product: ProductID(rawValue: 0x408A), category: .keyboard)
                    ?? Fixture.mouse(),
                physical: Fixture.physical(model: 0xB35B_408A_0000, unit: 2)
            )
        )

        #expect(mouse.identity.id != keyboard.identity.id)
        #expect(mouse.displaced == nil)
        #expect(keyboard.displaced == nil)
        #expect(registry.identity(for: mouse.identity.id)?.endpoint == boltSlot1)
    }

    @Test("adopts a firmware identity that becomes available after the first sighting")
    func adoptsPhysicalIdentity() {
        var registry = DeviceIdentityRegistry()
        let early = registry.reconcile(Fixture.observation(Fixture.bluetooth()))

        let late = registry.reconcile(Fixture.observation(Fixture.bluetooth(), physical: Fixture.physical(unit: 9)))
        let moved = registry.reconcile(Fixture.observation(boltSlot1, physical: Fixture.physical(unit: 9)))

        #expect(late.outcome == .adoptedPhysicalIdentity)
        #expect(late.identity.id == early.identity.id)
        #expect(moved.identity.id == early.identity.id)
    }

    @Test("keeps a known firmware identity when a later sighting cannot read it")
    func retainsPhysicalIdentity() {
        var registry = DeviceIdentityRegistry()
        let physical = Fixture.physical(unit: 3)
        _ = registry.reconcile(Fixture.observation(Fixture.bluetooth(), physical: physical))

        let degraded = registry.reconcile(Fixture.observation(Fixture.bluetooth()))

        #expect(degraded.outcome == .matchedEndpoint)
        #expect(degraded.identity.physical == physical)
    }

    @Test("a re-paired receiver slot gets a new identity and displaces the previous device")
    func slotRepairedWithAnotherDevice() {
        var registry = DeviceIdentityRegistry()
        let previous = registry.reconcile(Fixture.observation(boltSlot1, physical: Fixture.physical(unit: 1)))

        let replacement = registry.reconcile(Fixture.observation(boltSlot1, physical: Fixture.physical(unit: 2)))

        #expect(replacement.outcome == .registered)
        #expect(replacement.identity.id != previous.identity.id)
        #expect(replacement.displaced == previous.identity.id)
        #expect(registry.identity(for: previous.identity.id) == nil)
    }

    @Test("a different model on a known endpoint is a different device")
    func differentModelOnSameEndpoint() {
        var registry = DeviceIdentityRegistry()
        let first = registry.reconcile(Fixture.observation(boltSlot1))

        let other = registry.reconcile(
            Fixture.observation(boltSlot1, model: Fixture.mouse("MX Anywhere 3S", product: ProductID(rawValue: 0x4090)))
        )

        #expect(other.identity.id != first.identity.id)
        #expect(other.displaced == first.identity.id)
    }

    @Test("same unit number on different models does not collide")
    func unitNumbersAreScopedByModel() {
        var registry = DeviceIdentityRegistry()

        let first = registry.reconcile(Fixture.observation(boltSlot1, physical: Fixture.physical(model: 0x1, unit: 5)))
        let second = registry.reconcile(Fixture.observation(boltSlot2, physical: Fixture.physical(model: 0x2, unit: 5)))

        #expect(first.identity.id != second.identity.id)
    }

    @Test("suffixes a derived identifier that collides with a known device")
    func derivedIdentifierCollision() {
        var registry = DeviceIdentityRegistry()
        // Registered from its endpoint, then reports a firmware identity and moves
        // away: it keeps its endpoint-derived identifier.
        let original = registry.reconcile(Fixture.observation(Fixture.bluetooth()))
        _ = registry.reconcile(Fixture.observation(Fixture.bluetooth(), physical: Fixture.physical(unit: 1)))
        _ = registry.reconcile(Fixture.observation(boltSlot1, physical: Fixture.physical(unit: 1)))

        // An anonymous device of the same model on the vacated endpoint derives
        // the same identifier and must be suffixed.
        let newcomer = registry.reconcile(Fixture.observation(Fixture.bluetooth()))

        #expect(newcomer.outcome == .registered)
        #expect(newcomer.identity.id != original.identity.id)
        #expect(newcomer.identity.id.rawValue == original.identity.id.rawValue + "~2")
        #expect(registry.identity(for: original.identity.id)?.endpoint == boltSlot1)
    }

    @Test("reconciliation is deterministic for the same sequence of observations")
    func determinism() {
        let observations = [
            Fixture.observation(boltSlot1, physical: Fixture.physical(unit: 1)),
            Fixture.observation(Fixture.bluetooth("bt-2")),
            Fixture.observation(Fixture.bluetooth(), physical: Fixture.physical(unit: 1)),
        ]
        var first = DeviceIdentityRegistry()
        var second = DeviceIdentityRegistry()

        let firstRun = observations.map { first.reconcile($0).identity.id }
        let secondRun = observations.map { second.reconcile($0).identity.id }

        #expect(firstRun == secondRun)
        #expect(firstRun[0] == firstRun[2])
    }
}
