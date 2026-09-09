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
        // TestSupport (entity builders, linked only by tests — ticket 13) arrives
        // with the first domain entity; an empty target now would be scaffolding.
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
