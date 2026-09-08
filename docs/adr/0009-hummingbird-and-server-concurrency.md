# Hummingbird 2, with thin handlers and actors only where state is shared

The server framework is **Hummingbird 2**. The decisive argument is consistency with a principle already applied elsewhere: **Vapor 5's `main` requires `swift-tools-version:6.4` while released Swift is 6.3.3**, and [ADR 0008](0008-grdb-client-storage-and-offline-queue.md) chose OS 26 over 27 precisely because 27 is unreleased — adopting Vapor 5 would contradict that within a day. That leaves Vapor 4, which is stable and clean under strict concurrency but is the *legacy* line whose `EventLoopFuture` internals Vapor 5 exists to replace. Hummingbird 2 is the only candidate that is both stable and structured-concurrency-native, having removed the EventLoop API surface outright — which is what "maximise structured concurrency across every surface" asks for literally rather than approximately. Within it, **request handlers are thin and stateless over `Sendable` Core services, and actors are reserved for genuinely shared mutable state**.

## Considered Options

- **Vapor 4.** Genuinely clean under Swift 6 and by far the larger ecosystem, but architecturally pre-Swift-6 with async/await layered over an event-loop core. Choosing it means inheriting a migration to Vapor 5 later.
- **Vapor 5.** The right shape, at the wrong time: alpha, requiring an unreleased toolchain, and depending on a self-declared work-in-progress HTTP package at 0.1.0 pinned by commit SHA.
- **Bare SwiftNIO.** Rejected because ticket 06 already specifies routing, patch semantics, cursor pagination, `expand` and 410-vs-404 — most of a framework's job, described in prose. That is not the layer worth owning.
- **Actor-per-service.** The obvious-looking way to satisfy a structured-concurrency policy, and rejected deliberately: it serialises throughput that never needed serialising and introduces reentrancy bugs at every `await` where invariants were assumed to hold. Recorded so nobody "fixes" the stateless services into actors later.

## Consequences

- **We accept a materially smaller ecosystem**: 1.9k stars against Vapor's 26.2k, SSWG *incubating* rather than *graduated*, effectively one dominant maintainer, and far less prior art when debugging at 2am. This is a real cost, not a tiebreaker, and it is the main thing that would justify revisiting.
- The research's strongest point *for* Vapor was its far healthier OpenAPI transport package — **that advantage evaporates** because swift-openapi-generator supports neither `security` nor Merge Patch's absent-vs-null, so hand-written patch DTOs and middleware auth are required under any framework.
- **ServiceLifecycle is the default idiom** rather than something bolted on, which is how background work is structured: periodic tasks in a task group, no job queue, no cron, no external scheduler. Graceful shutdown drains in-flight requests and refuses new ones.
- Constructor-injected controllers make the server's composition root resemble the CLI's and MCP executable's, which is what [ADR 0002](0002-monorepo-shared-core-package.md) wanted from a shared Core package.
- If real-time work ever arrives, Hummingbird's WebSocket upgrade runs through the router with middleware, so the token auth from [ADR 0006](0006-auth-model.md) applies unchanged.
