// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Issues",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .executable(name: "issues-server", targets: ["issues-server"]),
        .executable(name: "issues", targets: ["issues-cli"]),
    ],
    dependencies: [
        // ADR 0009: the only candidate both stable and structured-concurrency
        // native. Versions from research/02-server-framework-landscape.md.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        // ADR 0010: embedded SQLite, one library across client and server.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // Already in the graph transitively via Hummingbird; declared explicitly so
        // `_CryptoExtras` (scrypt) can be imported. See ADR 0006's amendment.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
        // Already transitive via Hummingbird; declared so the reaper can be a Service.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        // Ticket 11 names it for the CLI's command grammar.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A library so it is testable; the executable below is a thin shell.
        .target(
            name: "Server",
            dependencies: [
                "Core",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "issues-server",
            dependencies: ["Server"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A library for the same reason `Server` is one: `main` cannot be tested.
        .target(
            name: "CLI",
            dependencies: [
                "Core",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "issues-cli",
            dependencies: ["CLI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Entity builders. Linked only by test targets, never shipped. Ticket 13.
        .target(
            name: "TestSupport",
            dependencies: ["Core"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ServerTests",
            dependencies: [
                "Server", "Core", "TestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Depends on `Server` so CLI commands run against the real router
        // rather than canned responses: the CLI exists to prove the contract.
        .testTarget(
            name: "CLITests",
            dependencies: [
                "CLI", "Core", "Server", "TestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
