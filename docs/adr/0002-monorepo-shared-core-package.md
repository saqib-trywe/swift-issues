# Single SwiftPM monorepo with a shared Core package

All five surfaces (Server, macOS/iOS/iPadOS apps, CLI, MCP interface) live in one repo: a shared Core Swift package (domain models, API client, validation) is consumed by a Server executable target, a CLI executable target, and an MCP server executable target, plus an Xcode project/workspace for the SwiftUI apps that also depends on Core. We chose this over separate repos per surface to maximize shared logic — the same domain types and API client back every client, so business rules and validation aren't reimplemented five times.
