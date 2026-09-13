// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Issues",
    // iOS is declared so the shared app layer can be built for it. The server and
    // CLI targets are macOS-only and simply are not part of an iOS build.
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Credentials", targets: ["Credentials"]),
        .library(name: "ClientStore", targets: ["ClientStore"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "AppViews", targets: ["AppViews"]),
        .executable(name: "issues-server", targets: ["issues-server"]),
        .executable(name: "issues", targets: ["issues-cli"]),
        // A throwaway gallery for looking at the shared components. Not shipped.
        .executable(name: "issues-preview", targets: ["issues-preview"]),
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
        // Token storage, shared by the CLI and the apps. Its own target because the
        // Keychain implementation cannot be exercised in CI, and folding it into
        // `Core` would mean lowering that module's coverage bar to suit the one
        // piece that cannot be measured.
        .target(
            name: "Credentials",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A library for the same reason `Server` is one: `main` cannot be tested.
        .target(
            name: "CLI",
            dependencies: [
                "Core",
                "Credentials",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "issues-cli",
            dependencies: ["CLI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The client's replica and offline queue. Apple-only by design (ticket 05,
        // input 3): the CLI and MCP are online-only and stateless, so nothing that
        // needs to build on Linux imports this.
        .target(
            name: "ClientStore",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The apps' shared behaviour layer: observable models and the five sync
        // surfaces' state. Ticket 10's variant C keeps this written once and
        // *placed* twice, so it lives here rather than in either app shell — which
        // also keeps it driveable from `swift test`.
        .target(
            name: "AppCore",
            dependencies: ["Core", "ClientStore", "Credentials"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The shared SwiftUI components. A separate target from `AppCore` because
        // ticket 13 gates view models and exempts view bodies: anything that can be
        // wrong lives in `AppCore` where it is tested, leaving these with nothing
        // to decide. Keeping them together would drag the gated figure down to
        // whatever fraction of the code happens to be views.
        .target(
            name: "AppViews",
            dependencies: ["AppCore", "Core", "ClientStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Renders every shared component with every sync state, so the views can be
        // looked at before the app shells exist. The successor to ticket 10's HTML
        // prototype, and just as throwaway.
        .executableTarget(
            name: "issues-preview",
            dependencies: ["AppViews", "AppCore", "Core", "ClientStore", "TestSupport"],
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
        // Depends on `Server` so the sync loop runs against the real router rather
        // than canned responses, exactly as `CLITests` does.
        .testTarget(
            name: "ClientStoreTests",
            dependencies: [
                "ClientStore", "Core", "Server", "TestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppViews", "AppCore", "Core", "ClientStore", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
