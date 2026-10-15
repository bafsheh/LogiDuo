// swift-tools-version: 6.0

import PackageDescription

/// Development tools built from source at exact versions so formatting is
/// identical on every machine and CI runner, independent of the Xcode in use.
let package = Package(
    name: "BuildTools",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-format.git", exact: "604.0.0")
    ],
    targets: []
)
