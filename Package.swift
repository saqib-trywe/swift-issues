// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Issues",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"])
    ],
    targets: [
        .target(
            name: "Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Entity builders. Linked only by test targets, never shipped. Ticket 13.
        .target(
            name: "TestSupport",
            dependencies: ["Core"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
