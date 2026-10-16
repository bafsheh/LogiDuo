import LogiDuoDomain
import Testing

@Suite("PermissionRequestPolicy")
struct PermissionRequestPolicyTests {
    @Test("granted permissions need nothing")
    func granted() {
        var policy = PermissionRequestPolicy()
        #expect(policy.actions(forEnabling: .remapping, statuses: [.accessibility: .granted]) == [.none])
    }

    @Test("a missing permission is prompted once per launch, then explained")
    func promptOnce() {
        var policy = PermissionRequestPolicy()
        #expect(
            policy.actions(forEnabling: .remapping, statuses: [.accessibility: .denied]) == [.prompt(.accessibility)]
        )
        #expect(
            policy.actions(forEnabling: .remapping, statuses: [.accessibility: .denied]) == [.instruct(.accessibility)]
        )
    }

    @Test("an Input Monitoring denial recorded by macOS is explained, never re-prompted")
    func recordedDenial() {
        var policy = PermissionRequestPolicy()
        #expect(
            policy.actions(forEnabling: .keyboardCommunication, statuses: [.inputMonitoring: .denied])
                == [.instruct(.inputMonitoring)]
        )
        #expect(
            policy.actions(forEnabling: .keyboardCommunication, statuses: [.inputMonitoring: .notDetermined])
                == [.prompt(.inputMonitoring)]
        )
    }

    @Test("each feature asks only for its own permission")
    func leastPrivilege() {
        #expect(PermissionedFeature.remapping.requiredPermissions == [.accessibility])
        #expect(PermissionedFeature.keyboardCommunication.requiredPermissions == [.inputMonitoring])
    }
}
