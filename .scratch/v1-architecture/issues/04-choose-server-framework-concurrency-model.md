# Choose server framework & concurrency model

Type: grilling
Status: resolved

Blocked by: 02

## Question

Given the findings from [Server framework landscape research](../issues/02-server-framework-research.md), choose the server framework and the concurrency architecture around it: how requests are handled (actor-isolated services? plain async functions?), how background work (sync fan-out, any scheduled jobs) is structured with structured concurrency, and how this choice affects Linux deployability. Record the choice as an ADR.

## Inherited constraints (from resolved ticket 05)

- Ticket 05 settled what the project's **strict-concurrency "hard gate" means: the compiler proves our data-race safety**, not merely that the code builds in Swift 6 language mode. Apply the same reading here — under the weak reading `@unchecked Sendable` satisfies the gate and the structured-concurrency policy is decorative.
- Research finding relevant to this choice: **swift-openapi-generator supports neither `security` nor Merge Patch's absent-vs-null**, so ticket 06's contract needs hand-written patch DTOs and middleware auth under any framework. Generation from an OpenAPI spec is not available as a shortcut.

## Resolution

**Hummingbird 2**, thin async handlers over `Sendable` Core services, **SQLite via GRDB**, deployed as a **macOS-only** process. Recorded in [ADR 0009](../../../docs/adr/0009-hummingbird-and-server-concurrency.md) and [ADR 0010](../../../docs/adr/0010-macos-single-process-server.md). Findings: [research/02-server-framework-landscape.md](../research/02-server-framework-landscape.md).

### Framework: Hummingbird 2

The decisive argument is consistency with a principle this project already applied: **Vapor 5's `main` requires `swift-tools-version:6.4` while released Swift is 6.3.3.** Ticket 05 chose OS 26 over 27 precisely because 27 is unreleased; adopting Vapor 5 would contradict that within a day.

That leaves Vapor 4 — stable and genuinely clean under strict concurrency, but the *legacy* line, with `EventLoopFuture` load-bearing internals that Vapor 5 exists to replace. Adopting it means owning that migration later.

**Hummingbird 2 is the only candidate that is both stable and structured-concurrency-native** — it removed the EventLoop API surface outright ("Hummingbird v2 is now exclusively Swift concurrency based. All EventLoop based APIs have been removed."), which is what the map's "maximise structured concurrency across every surface" asks for literally rather than approximately.

**Bare NIO rejected**: ticket 06 already specifies routing, patch semantics, cursor pagination, `expand`, and 410-vs-404 — most of a framework's job, described in prose. That is not the layer worth owning.

**Cost, plainly**: 1.9k stars against Vapor's 26.2k, SSWG *incubating* rather than *graduated*, effectively one dominant maintainer, and far less prior art when debugging at 2am. A real trade, not a tiebreaker. Noted: the research's strongest point *for* Vapor was its far healthier OpenAPI transport package, and that advantage evaporates because the generator supports neither `security` nor Merge Patch's absent-vs-null — so hand-written patch DTOs and middleware auth are required under any framework.

### Server database: SQLite via GRDB

Not previously ticketed — the gap was found while resolving this ticket. Reasons in order of weight:

1. **It eliminates a class of sync bug.** Ticket 06 specified the pull watermark as an opaque monotonic server sequence. With concurrent writers, sequence values can commit *out of order*, so a client can observe watermark 5 before 4 is visible and skip change 4 permanently — silent, unrecoverable, and notoriously hard to reproduce. SQLite in WAL serialises writers, so the window cannot open. Postgres requires deliberate work to avoid it.
2. **Operational weight** — single-tenant by ADR 0001, and now a single Mac (ADR 0010). No second service; backup is copying a file. Requiring a Postgres install contradicts the lightweight premise as directly as requiring SMTP did in ticket 07.
3. **One storage library across client and server**, with one set of migration idioms to learn.

**Cost**: no horizontal scaling (irrelevant — single-tenant, single box by design), and outgrowing a single writer would make a Postgres move a real project rather than a config change.

### Request-handling concurrency

**Thin, stateless async handlers over Core services that are `Sendable` structs or final classes. Actors are reserved for genuinely shared mutable state** — rate-limit buckets, login-throttle counters, the bootstrap-token holder.

Making every service an actor is the failure mode to avoid: it serialises throughput that never needed serialising and introduces reentrancy bugs at every `await` where invariants were assumed to hold. Almost all request handling is stateless — parse, call Core, hit the database, return — and the concurrency that matters is owned by the connection pool. This also matches Hummingbird's constructor-injected controller style, so the server's composition root looks like the CLI's and the MCP executable's (ADR 0002).

### Background work

v1 is pull-based, so there is no sync fan-out. What runs in the background is small: expired-session reaping, bootstrap-token expiry, coarse last-used flushing.

**ServiceLifecycle-managed periodic tasks in a task group — no job queue, no cron, no external scheduler.** Hummingbird's `ApplicationProtocol: Service` makes ServiceLifecycle the default idiom rather than something bolted on, which is one concrete way the framework choice pays off. Graceful shutdown drains in-flight requests with a timeout and refuses new ones. **A sync push must not be left in a broken state at shutdown.** ~~Since each batch is one transaction, that falls out of the database.~~ **Corrected while resolving ticket 08**: a batch is *not* one transaction — one transaction per operation, because a single-transaction batch would let one rejected operation roll back the rest, violating ADR 0004's no-head-of-line-blocking rule. The real guarantee is **idempotent replay**: interrupted mid-batch, the client retries the identical batch, already-applied `opId`s dedupe, and the rest apply.

### Deployability

**macOS only.** No Linux build, no container, no Linux CI — see [ADR 0010](../../../docs/adr/0010-macos-single-process-server.md). This supersedes the Linux framing in this ticket's original question and in ticket 09's. Linux deployability consequently did not influence the framework choice, which is consistent with the research finding that it barely differentiates anyway.

Note the CLI's Linux credential fallback (ticket 11) is now **incidental rather than required** — harmless to keep, but no longer a supported target unless separately decided.
