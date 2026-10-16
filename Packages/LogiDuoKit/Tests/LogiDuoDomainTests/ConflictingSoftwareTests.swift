import LogiDuoDomain
import Testing

@Suite("ConflictingSoftware")
struct ConflictingSoftwareTests {
    @Test(
        "Logitech software and Mouser are recognised; unrelated apps are not",
        arguments: [
            (String?.some("com.logi.optionsplus"), "Logi Options+", ConflictingSoftware?.some(.logiOptionsPlus)),
            ("com.logi.ghub", "G HUB", .gHub),
            ("com.logitech.manager.daemon", "Logi Options Daemon", .logitechOptions),
            (nil, "Mouser", .mouser),
            ("com.apple.Safari", "Safari", nil),
            ("io.github.bafsheh.LogiDuo", "LogiDuo", nil),
        ]
    )
    func classify(bundle: String?, name: String, expected: ConflictingSoftware?) {
        #expect(ConflictingSoftware.classify(bundleIdentifier: bundle, name: name) == expected)
    }
}
