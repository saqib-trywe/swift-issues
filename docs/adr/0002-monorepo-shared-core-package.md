# Single SwiftPM monorepo with a shared Core package

All five surfaces (Server, macOS/iOS/iPadOS apps, CLI, MCP interface) live in one repo: a shared Core Swift package (domain models, API client, validation) is consumed by a Server executable target, a CLI executable target, and an MCP server executable target, plus an Xcode project/workspace for the SwiftUI apps that also depends on Core. We chose this over separate repos per surface to maximize shared logic — the same domain types and API client back every client, so business rules and validation aren't reimplemented five times.

## Layout (decided 2026-09-08, before implementation)

**The SwiftPM package lives at the repository root** — `Package.swift`, `Sources/` and `Tests/` sit alongside `docs/` and `.scratch/`. Conventional for a monorepo, and it means `swift build` and `swift test` work from the top with no path arguments, which matters for the `Makefile` and pre-commit hook in ticket 13. The cost is cosmetic: spec directories and source directories share the root listing.

Targets follow this ADR's structure: a `Core` library (domain models, validation, API client, sync logic), `Server`, `CLI` and `MCP` executables, a `TestSupport` target linked only by tests (ticket 13), and a separate Xcode project/workspace for the SwiftUI apps depending on `Core`.
