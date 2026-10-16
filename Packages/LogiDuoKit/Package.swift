// swift-tools-version: 6.0

import PackageDescription

/// Settings shared by every first-party target.
///
/// Swift 6 language mode (complete strict concurrency checking) is the default
/// for tools-version 6.0; the upcoming features below tighten it further.
let strictSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

/// A first-party library target together with its test target.
///
/// Layer rules (also enforced by scripts/check-architecture.sh):
/// * Domain depends on nothing but Foundation.
/// * Infrastructure targets (HIDPP, HID, System, Persistence) depend on Domain;
///   LogiDuoHID (IOKit) additionally builds on the transport-independent LogiDuoHIDPP.
/// * Features (presentation) depends on Domain only; infrastructure is injected
///   by the application's composition root.
struct Layer {
    let name: String
    let dependencies: [Target.Dependency]
    let resources: [Resource]?

    init(_ name: String, dependencies: [Target.Dependency] = [], resources: [Resource]? = nil) {
        self.name = name
        self.dependencies = dependencies
        self.resources = resources
    }
}

let layers: [Layer] = [
    Layer("LogiDuoDomain"),
    Layer("LogiDuoHIDPP", dependencies: ["LogiDuoDomain"]),
    Layer("LogiDuoHID", dependencies: ["LogiDuoDomain", "LogiDuoHIDPP"]),
    Layer("LogiDuoSystem", dependencies: ["LogiDuoDomain"]),
    Layer("LogiDuoFeatures", dependencies: ["LogiDuoDomain"], resources: [.process("Resources")]),
]

let package = Package(
    name: "LogiDuoKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: layers.map { .library(name: $0.name, targets: [$0.name]) },
    targets: layers.flatMap { layer -> [Target] in
        [
            .target(
                name: layer.name,
                dependencies: layer.dependencies,
                resources: layer.resources,
                swiftSettings: strictSwiftSettings
            ),
            .testTarget(
                name: "\(layer.name)Tests",
                dependencies: [.target(name: layer.name), "LogiDuoTestSupport"],
                swiftSettings: strictSwiftSettings
            ),
        ]
    } + [
        // Physical-device and live-system verification. Skipped unless LOGIDUO_HARDWARE=1
        // or LOGIDUO_SYSTEM=1 is set, so CI and ordinary test runs never touch real
        // hardware or install event taps.
        .testTarget(
            name: "LogiDuoHardwareTests",
            dependencies: ["LogiDuoDomain", "LogiDuoHIDPP", "LogiDuoHID", "LogiDuoSystem"],
            swiftSettings: strictSwiftSettings
        ),
        // Test doubles shared by test targets. Never linked into the app.
        .target(
            name: "LogiDuoTestSupport",
            dependencies: ["LogiDuoDomain", "LogiDuoHIDPP"],
            path: "Tests/LogiDuoTestSupport",
            swiftSettings: strictSwiftSettings
        ),
    ]
)
