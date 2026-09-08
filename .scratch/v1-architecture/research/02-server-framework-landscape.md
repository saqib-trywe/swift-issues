# Server framework landscape (Vapor / Hummingbird / SwiftNIO)

Research for [ticket 02](../issues/02-server-framework-research.md). Feeds the decision in [ticket 04](../issues/04-choose-server-framework-concurrency-model.md). **No recommendation here** — findings only.

Surveyed 2026-09-07. Every substantive claim carries a primary-source URL (GitHub repos/API, official docs, swift.org, Swift Forums, Swift Package Index).

## Baseline: latest released Swift

**Swift 6.3.3, released 2026-06-30** — latest patch of the 6.3 line (6.3.0 shipped 2026-03-27).

- swift.org Linux install page headline version: **6.3.3** — https://www.swift.org/install/linux/
- Tag dates confirmed against the release list: `swift-6.3.3-RELEASE` published 2026-06-30, `swift-6.3-RELEASE` published 2026-03-27 — https://github.com/swiftlang/swift/releases

The project's "latest released Swift, latest-released-only platforms" policy therefore means **Swift 6.3.x with `swift-tools-version: 6.x` and Swift 6 language mode (full strict concurrency) on by default**. That matters: strict concurrency is not opt-in for this project, so a framework's `Sendable` story is a hard requirement rather than a nice-to-have.

## Summary

Three live options, and the headline is a **timing problem**, not a capability problem.

| | Latest release | Swift 6 story |
| --- | --- | --- |
| **Vapor 4** | 4.122.1 (2026-08-25) | Ships with strict concurrency clean, but is the *legacy* line — `main` is now Vapor 5 |
| **Vapor 5** | 5.0.0-alpha.2 (2026-08-11) | Ground-up rewrite, structured-concurrency native — **alpha**, depends on an untagged revision of a 0.1.0 package |
| **Hummingbird 2** | 2.26.0 (2026-07-29) | Designed post-Swift-6; `Sendable` router, ServiceLifecycle-based |
| **SwiftNIO** | 2.102.0 (2026-09-01) | Foundation layer for all of the above; async bridges are stable but it is not an HTTP framework |

Sources: [vapor releases](https://github.com/vapor/vapor/releases), [hummingbird releases](https://github.com/hummingbird-project/hummingbird/releases), [swift-nio releases](https://github.com/apple/swift-nio/releases).

The live tension for a project starting today: Vapor's *stable* line is architecturally pre-Swift-6 (event-loop-shaped internals with async/await layered over), Vapor's *modern* line is alpha, and Hummingbird 2 is the only option that is both stable and structured-concurrency-native. Bare NIO is a real option only if you are prepared to write routing, content negotiation and middleware yourself.

---

## Vapor

The incumbent. MIT, ~26.2k stars, easily the largest server-side Swift community. Two active lines.

### Maturity / activity

- **Vapor 4 — latest 4.122.1, 2026-08-25.** Maintained on the `vapor4` branch; `main` is now Vapor 5. Cadence on the 4.12x line is steady (4.122.0 on 2026-07-01, 4.121.4 on 2026-04-10). [releases](https://github.com/vapor/vapor/releases), [branch list](https://github.com/vapor/vapor/branches)
- **Vapor 5 — 5.0.0-alpha.1 (2026-06-11, announced at WWDC/CommunityKit), 5.0.0-alpha.2 (2026-08-11).** No beta as of survey date. [5.0.0-alpha.1 notes](https://github.com/vapor/vapor/releases/tag/5.0.0-alpha.1)
- Repo health: 80 open issues, 26 open PRs, 71 commits on `main` in the last 90 days, last push 2026-09-05. [GitHub API](https://api.github.com/repos/vapor/vapor) — healthy backlog for a project this size.

Vapor 5's own release notes describe it as *"a major overhaul of all of Vapor's internals … removal of 7 years of tech debt … full structured concurrency support … type safe routing with macros for parameters and authentication with a new controller macro"*, and note it is *"built on top of a new HTTP Server from Swift"* ([alpha.1 notes](https://github.com/vapor/vapor/releases/tag/5.0.0-alpha.1)).

**The dependency to look at hard.** That "new HTTP Server" is [`swift-server/swift-http-server`](https://github.com/swift-server/swift-http-server), whose README opens with *"🚧 This project is a work in progress 🚧"*. Its only tag is **0.1.0**, and Vapor 5 alpha.2 pins it by **commit revision**, not version:

```swift
.package(url: "https://github.com/swift-server/swift-http-server.git",
         revision: "5c6314bb63cd369b400b1b4a8bee40975411e965"),
```
([Package.swift @ 5.0.0-alpha.2](https://github.com/vapor/vapor/blob/5.0.0-alpha.2/Package.swift))

Vapor 5's `main` also declares `// swift-tools-version:6.4` and `.macOS("26.2")` ([Package.swift @ main](https://github.com/vapor/vapor/blob/main/Package.swift)) — i.e. current Vapor 5 development targets a toolchain **newer than the latest released Swift (6.3.3)**. The tagged alpha.2 is `swift-tools-version:6.2`, so the *tag* builds on 6.3, but the development tip does not.

### Swift 6 / strict concurrency

**Vapor 4 is clean under Swift 6 language mode.** This is not aspirational — it is in the type declarations:

- `public final class Request: CustomStringConvertible, Sendable` ([Request.swift](https://github.com/vapor/vapor/blob/vapor4/Sources/Vapor/Request/Request.swift))
- `public final class Application: Sendable`, with internal mutable state held in `NIOLockedValueBox` rather than `@unchecked` ([Application.swift](https://github.com/vapor/vapor/blob/vapor4/Sources/Vapor/Application.swift))
- Route registration takes `@Sendable @escaping` closures throughout ([RoutesBuilder+Method.swift](https://github.com/vapor/vapor/blob/vapor4/Sources/Vapor/Routing/RoutesBuilder%2BMethod.swift))
- Every `Sendable`-titled issue in the tracker is closed; the "Add Sendable Conformances to Vapor" umbrella (#3000) closed 2023-11 and the follow-ups (#3054, #3056, #3341, #3345, #3424) are all closed. [issue search](https://github.com/vapor/vapor/issues?q=Sendable+in%3Atitle)
- Blocking APIs are annotated: `@available(*, noasync, message: "This can block the thread and should not be called in an async context", renamed: "asyncShutdown()")` ([Application.swift](https://github.com/vapor/vapor/blob/vapor4/Sources/Vapor/Application.swift)), the outcome of #3168.

**But "compiles under Swift 6" is not the same as "structured-concurrency-shaped".** Vapor 4's own docs still frame the runtime as an event-loop model: *"Each time a client connects to your server, it will be assigned to one of the event loops"*, route closures must stay on `req.eventLoop`, and blocking work is offloaded to `req.application.threadPool.runIfActive()` rather than to a task or an actor ([Async docs](https://docs.vapor.codes/basics/async/)). The docs do steer you to async/await — *"you should use `async`/`await` as the benefits or readability and maintainability far outweigh any small performance penalty"* — with `EventLoopFuture` reserved for *"applications that need explicit control over event loops, or very high performance applications"* ([same page](https://docs.vapor.codes/basics/async/)). So the async surface is complete and recommended, but `EventLoopFuture` is still load-bearing in the API and in the surrounding ecosystem (Fluent, older community packages), and there is no first-class notion of running a handler on an actor — you `await` into your own actors from a `@Sendable` closure.

### WebSocket / SSE

- **WebSocket: yes, but callback-shaped.** `app.webSocket("echo") { req, ws in … }` with `ws.onText { ws, text in }` / `ws.onBinary`, `try await ws.close()`, and `ws.onClose.whenComplete` — i.e. handlers are closures, not an `AsyncSequence` you can `for await` over ([WebSockets docs](https://docs.vapor.codes/advanced/websockets/)). There is an unmerged `async-websockets` branch on the repo ([branches](https://github.com/vapor/vapor/branches)).
- **SSE: no first-class support in Vapor 4.** [PR #2960 "Implement Server-Sent Events"](https://github.com/vapor/vapor/pull/2960) has been open since 2024; [issue #2959](https://github.com/vapor/vapor/issues/2959) (SSE consumption) is also open. What *is* supported is async response-body streaming ([PR #2998, merged](https://github.com/vapor/vapor/pull/2998)), so SSE is hand-rollable over an async body stream — you write the `text/event-stream` framing yourself. There is a `feature/jo-sse` branch in-flight ([branches](https://github.com/vapor/vapor/branches)).

### Linux deployment

Best-documented of the three, and the official template is a genuinely production-shaped two-stage Dockerfile ([vapor/template Dockerfile](https://github.com/vapor/template/blob/main/Dockerfile)):

- Build stage `FROM swift:6.3-noble`; runtime stage `FROM ubuntu:noble` — Ubuntu 24.04 LTS on both sides.
- Builds with `--static-swift-stdlib` and links jemalloc (`-Xlinker -ljemalloc`), with an explicit warning that *"The static version of jemalloc is incompatible with the static Swift runtime."*
- Runtime image installs only `libjemalloc2`, `ca-certificates`, `tzdata`, plus commented-out `libcurl4` (needed only if something imports `FoundationNetworking`) and `libxml2` (`FoundationXML`). So the **Foundation tax is opt-in**: core Foundation is in the static stdlib, and you only pull system libs if you reach for the networking/XML sub-modules.
- Copies `swift-backtrace-static` into the image so crashes still symbolicate.
- Vapor's [Docker deploy docs](https://docs.vapor.codes/deploy/docker/) describe the two-stage arrangement but leave the concrete base images to the template.

Fully-static musl builds (`swift build --swift-sdk x86_64-swift-linux-musl`) are a separate, toolchain-level option that applies to any of the three frameworks — see the Linux section below.

### Rough edges

- **The version question dominates everything else.** Choosing Vapor today means choosing between a stable line that is explicitly in tech-debt-removal maintenance and an alpha whose transitive HTTP server is a 0.1.0 work-in-progress pinned by SHA.
- `EventLoopFuture` remains in the public API and in ecosystem packages; you cannot fully avoid it, only avoid writing it.
- Large surface area — templating (Leaf), sessions, validation, Fluent ORM, console — most of which this project would not use. Vapor 5 mitigates this with package traits (`WebSockets`, `bcrypt`, `HTTPClient`, `Multipart`, `MacroRouting`) ([Package.swift @ main](https://github.com/vapor/vapor/blob/main/Package.swift)), Vapor 4 does not.
- No ServiceLifecycle integration in shipping Vapor 4 (there is an unmerged `service-lifecycle` branch); graceful shutdown is Vapor's own `Application.asyncShutdown()`. Vapor 5 alpha does depend on `swift-service-lifecycle` 2.6.3 ([Package.swift @ 5.0.0-alpha.2](https://github.com/vapor/vapor/blob/5.0.0-alpha.2/Package.swift)).

---

## Hummingbird

Apache 2.0, ~1.9k stars. Much smaller community than Vapor, but the only stable framework here that was designed *after* Swift concurrency landed. **SSWG incubating** ([swift.org incubated packages](https://www.swift.org/sswg/incubated-packages.html); the badge is also in the [README](https://github.com/hummingbird-project/hummingbird)).

### Maturity / activity

- **Latest release 2.26.0, 2026-07-29**; the 2.2x line is on a roughly monthly cadence (2.25.1 on 2026-07-14, 2.25.0 on 2026-05-29, 2.24.0 on 2026-05-22). [releases](https://github.com/hummingbird-project/hummingbird/releases)
- **No v3 in flight.** `main` is the 2.x line; there is a `1.x.x` maintenance branch and a set of experimental feature branches (`swift-http-server`, `swift-server-api`, `non-copyable-request`, `jo/windows-support`) but no announced major rewrite. [branches](https://github.com/hummingbird-project/hummingbird/branches) — this is the sharpest contrast with Vapor.
- Repo health: 18 open issues, 6 open PRs, 36 commits in the last 90 days, last push 2026-09-07. [GitHub API](https://api.github.com/repos/hummingbird-project/hummingbird) — a small, tidy backlog rather than a neglected one.
- **Bus-factor caveat.** The project is overwhelmingly the work of one maintainer (adam-fowler); the feature branches are prefixed `jo/`. Worth weighing against Vapor's larger contributor base.
- Ecosystem is modular and lives in separate repos: `hummingbird-auth`, `hummingbird-websocket`, `swift-jobs`, `hummingbird-postgres`, `swift-mustache`, `hummingbird-lambda`, `swift-openapi-hummingbird` ([org repo list](https://github.com/orgs/hummingbird-project/repositories)). Several of these have **no tagged releases at all** (`hummingbird-auth`, `swift-jobs`) despite active commits — you consume them from a branch or a revision.

### Swift 6 / strict concurrency

This is Hummingbird's strongest card, and it is stated outright in the project's own migration guide:

> "Hummingbird v2 is now exclusively Swift concurrency based. All EventLoop based APIs have been removed."
> — [Migrating to Hummingbird v2](https://docs.hummingbird.codes/2.0/documentation/hummingbird/migratingtov2)

Concretely, from the source:

- `public struct Request: Sendable` — a value type, and the body is an `AsyncSequence` of `ByteBuffer` rather than a collated buffer ([Request.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Sources/HummingbirdCore/Request/Request.swift)). The migration guide notes the default flipped in v2: *"It is assumed that request bodies are a stream of buffers and if you want to collate them into one buffer you need to call a method to do that."*
- **Every** route-registration overload takes `@Sendable @escaping (Request, Context) async throws -> some ResponseGenerator`. There is no future-returning variant to accidentally reach for ([RouterMethods.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Sources/Hummingbird/Router/RouterMethods.swift)).
- `ResponseBody: Sendable` with `init(asyncSequence:)` and a `@Sendable (inout any ResponseBodyWriter) async throws -> Void` closure form ([ResponseBody.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Sources/HummingbirdCore/Response/ResponseBody.swift)).
- `Package.swift` is `swift-tools-version:6.1` — so Swift 6 language mode by default — and additionally opts into `ExistentialAny`, `MemberImportVisibility` and `InternalImportsByDefault` upcoming features ([Package.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Package.swift)). That is a project running *ahead* of the strictness this project needs, not catching up to it.

**The `RequestContext` design is the thing to actually evaluate.** Instead of Vapor's "extend `Request` with your own storage", Hummingbird makes the context a generic parameter on the router:

```swift
public protocol RequestContext: InitializableFromSource, RequestContextSource {
    associatedtype Decoder: RequestDecoder = JSONDecoder
    associatedtype Encoder: ResponseEncoder = JSONEncoder
    var coreContext: CoreRequestContextStorage { get set }
    ...
}
```
([RequestContext.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Sources/Hummingbird/Server/RequestContext.swift))

The guide is explicit that this replaced both `Application` extension and `Request` extension with *"a model of explicit dependency injection"*, where *"for each route controller you supply the dependencies you need at initialization"* ([migration guide](https://docs.hummingbird.codes/2.0/documentation/hummingbird/migratingtov2)). For a design that wants actor-isolated services (a sync actor, a store actor) injected into handlers rather than fished out of a global, that is a direct fit — but it also means your context type is a generic parameter threaded through every router, middleware and test, which is real friction the first time you add a field.

`ApplicationProtocol: Service` — the application *is* a ServiceLifecycle `Service`, with `runService(gracefulShutdownSignals: [.sigterm, .sigint])` as the entry point ([Application.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Sources/Hummingbird/Application.swift)). So graceful shutdown, ordered startup of a database pool alongside the HTTP server, and signal handling are the framework's default idiom rather than something you bolt on.

### WebSocket / SSE

- **WebSocket: AsyncSequence-shaped, not callback-shaped.** From [HummingbirdWebSocket](https://github.com/hummingbird-project/hummingbird-websocket) (latest **2.7.0, 2026-05-22**):

  ```swift
  wsRouter.ws("/ws") { request, context in .upgrade() }
  onUpgrade: { inbound, outbound, context in
      for try await packet in inbound { try await outbound.write(.text("Received")) }
  }
  ```
  Upgrades go through a separate `Router(context: BasicWebSocketRequestContext.self)`, so **middleware — including auth — runs on the upgrade request**. That matters for this project: a WebSocket future thread would reuse the same token middleware rather than needing a parallel auth path.
- **SSE: not in core, but there is a working path.** `SSEKit` exists at [hummingbird-project/sse-kit](https://github.com/hummingbird-project/sse-kit) — **no tagged release, last pushed 2024-09-14** — and there is an official [`server-sent-events` example](https://github.com/hummingbird-project/hummingbird-examples/tree/main/server-sent-events) that combines `SSEKit`, `AsyncAlgorithms` and a `Publisher` fan-out. Absent SSEKit, `ResponseBody(asyncSequence:)` makes hand-rolled `text/event-stream` straightforward. Treat SSE as "buildable in an afternoon", not "supported".

### Linux deployment

Essentially identical to Vapor's, from the same playbook ([hummingbird-project/template Dockerfile](https://github.com/hummingbird-project/template/blob/main/Dockerfile)):

- `FROM swift:6.3-noble` to build, `FROM ubuntu:noble` to run.
- `swift build -c release --static-swift-stdlib -Xlinker -ljemalloc`, `swift-backtrace-static` copied into the image, runtime installs only `libjemalloc2`, `ca-certificates`, `tzdata`.
- **Lower Foundation exposure by design.** The migration guide states the intent to *"limit our exposure to only the elements of Foundation that will be in FoundationEssentials"* ([migration guide](https://docs.hummingbird.codes/2.0/documentation/hummingbird/migratingtov2)); core Hummingbird's dependency list is all `apple/swift-*` and `swift-server/*` packages with no Foundation-heavy extras ([Package.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Package.swift)).
- Platform floor is low (`macOS 11 / iOS 15`) and it carries an `AvailabilityMacro` entry for **Android 28** under `compiler(>=6.3)` ([Package.swift](https://github.com/hummingbird-project/hummingbird/blob/main/Package.swift)) — indicative of ongoing non-Apple-platform work.

### Rough edges

- **`swift-openapi-hummingbird` is the weak link if you go the OpenAPI route.** Latest release **2.0.1, 2024-09-30**; last commit **2025-05-08** ("Drop swift 5.9, add CI for swift 6.1"); `Package.swift` still declares `// swift-tools-version: 5.10` — i.e. **not** in Swift 6 language mode ([Package.swift](https://github.com/hummingbird-project/swift-openapi-hummingbird/blob/main/Package.swift)). It is a thin transport shim, so this is survivable and forkable, but it is 16 months without a commit against a generator that shipped 1.13.1 on 2026-09-01.
- Generic `RequestContext` threading is the tax for the dependency-injection design; type errors involving it are verbose.
- Small ecosystem: no batteries-included ORM story of Fluent's maturity (there is `hummingbird-fluent`, which just wraps Vapor's), fewer StackOverflow/forum answers, fewer example codebases.
- Untagged dependencies (`hummingbird-auth`, `swift-jobs`) mean pinning by revision if you need them.
- One dominant maintainer.

---

## SwiftNIO (bare)

Apache 2.0, Apple-maintained, ~8.5k stars. **SSWG graduated** ([incubated packages](https://www.swift.org/sswg/incubated-packages.html)). This is the layer both Vapor and Hummingbird sit on; "choosing NIO" means choosing to write the HTTP framework layer yourself.

### Maturity / activity

- **Latest release 2.102.0, 2026-09-01**; 2.101.x through July 2026. Cadence is roughly monthly with frequent patches. [releases](https://github.com/apple/swift-nio/releases)
- Repo health: 186 open issues, 108 open PRs, 49 commits in the last 90 days, last push 2026-09-07. [GitHub API](https://api.github.com/repos/apple/swift-nio) — a large backlog, but proportionate to a project this size and this old, and clearly actively worked (recent work includes a Windows port and `NIOFileSystem` fixes, per the [2.102.0 notes](https://github.com/apple/swift-nio/releases/tag/2.102.0)).
- **NIO 2 is still the supported major line** — the README's repository table pins core NIO at `from: "2.0.0"` with no NIO 3 mentioned ([README](https://github.com/apple/swift-nio/blob/main/README.md)). No looming migration, unlike Vapor.
- Strict SemVer discipline: release notes are categorised "SemVer Minor" / "SemVer Patch" ([2.102.0](https://github.com/apple/swift-nio/releases/tag/2.102.0)).

### Swift 6 / strict concurrency

- `Package.swift` is `swift-tools-version:6.1` (Swift 6 language mode by default) and opts into the experimental `Lifetimes` feature, with a comment explaining the Language Steering Group's stability promise ([Package.swift](https://github.com/apple/swift-nio/blob/main/Package.swift)).
- The structured-concurrency bridge is `NIOAsyncChannel`, and it is fully `Sendable`-constrained public API, not underscored or experimental:

  ```swift
  public struct NIOAsyncChannel<Inbound: Sendable, Outbound: Sendable>: Sendable
  ```
  with `executeThenClose { inbound, outbound in ... }` as the supported scoped form; the older non-scoped `.inbound` / `.outbound` properties are **deprecated** in favour of it ([AsyncChannel.swift](https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/AsyncChannel/AsyncChannel.swift)).
- **But NIO's own model is not structured concurrency.** The README is explicit that `EventLoopPromise`/`EventLoopFuture` are the core abstraction for asynchronous operations ([README, "Conceptual Overview"](https://github.com/apple/swift-nio/blob/main/README.md)), and 2.102.0 is still adding future-shaped API (e.g. "Add variants of flatMap which can return `EventLoopFuture<NonSendable>`"). `ChannelHandler`s are event-loop-isolated, not actor-isolated. You get a clean async *edge*; behind it you are writing pipeline code.

### WebSocket / SSE

- `NIOWebSocket` ships **in the core repo** and supports both client and server ([README protocol table](https://github.com/apple/swift-nio/blob/main/README.md)). It is a low-level frame codec, though — you handle upgrade negotiation, masking policy, ping/pong and close handshakes at the `ChannelHandler` level.
- SSE has no NIO-level concept; it is just a long-lived HTTP/1.1 response with `text/event-stream` framing you write into an outbound writer.
- Everything above HTTP/1 is a separate package: HTTP/2 in [swift-nio-http2](https://github.com/apple/swift-nio-http2), TLS in [swift-nio-ssl](https://github.com/apple/swift-nio-ssl), QUIC/HTTP3 still `branch: "main"`-only ([README](https://github.com/apple/swift-nio/blob/main/README.md)).

### Linux deployment

The best of the three, because there is least of it. NIO is the platform layer: `NIOPosix` for Linux I/O, `NIOTransportServices` for Apple platforms. Foundation is **opt-in via a separate module** — `NIOFoundationCompat` exists specifically so that "if you are working with Foundation data types such as `Data`, you should import this" ([README module list](https://github.com/apple/swift-nio/blob/main/README.md)); core NIO uses `ByteBuffer`. That makes a NIO-only server the easiest of the three to build fully static against musl.

### Rough edges

- **You are writing a framework.** Routing, path parameters, `Codable` request/response binding, content negotiation, middleware chaining, multipart, cookie/session handling, graceful shutdown wiring — none of that exists at this layer. For a project whose HTTP contract is already fully specified (ticket 06: two contracts, merge-patch semantics, cursor pagination, `expand`, 410-vs-404), that is a substantial and entirely undifferentiated build.
- The `ChannelPipeline` mental model is a genuine learning cost and the main source of subtle bugs (backpressure, half-closure, handler removal ordering).
- Future-based API is unavoidable at this layer.

### The in-between option: `swift-server/swift-http-server`

Worth naming separately, because it is what Vapor 5 is being rebuilt on and Hummingbird has a `swift-http-server` branch exploring too ([hummingbird branches](https://github.com/hummingbird-project/hummingbird/branches)).

- Apple-authored, under the `swift-server` org. README: *"a low-level yet ergonomic API for handling HTTP requests and responses with full support for bi-directional streaming, request and response trailers, and Structured Concurrency-based resource management."* ([README](https://github.com/swift-server/swift-http-server))
- **Status: `🚧 This project is a work in progress 🚧`** (its own README). Only tag is **0.1.0, 2026-07-03**. 25 open issues, 23 commits in the last 90 days. [repo](https://github.com/swift-server/swift-http-server)
- `main` declares `// swift-tools-version:6.4` — **newer than released Swift 6.3.3** ([Package.swift](https://github.com/swift-server/swift-http-server/blob/main/Package.swift)).
- HTTP/3 is available behind a package trait but requires `SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1` because the dependency tree pulls a **beta** swift-crypto ([README](https://github.com/swift-server/swift-http-server)).

Not a v1 candidate on its own, but it is the reason Vapor 5's timeline is uncertain: Vapor 5 cannot reasonably go 1.0 before its HTTP server does.

---

## swift-openapi-generator and the SSWG package floor

### swift-openapi-generator

Apple-maintained, **SSWG incubating** ([incubated packages](https://www.swift.org/sswg/incubated-packages.html)). A SwiftPM build plugin that generates `Codable` types plus a server `APIProtocol` from an OpenAPI 3.0.3/3.1.0 document, so the contract and the code cannot drift.

- **Latest 1.13.1, 2026-09-01** (1.13.0 on 2026-07-06); runtime `swift-openapi-runtime` **1.12.1, 2026-09-02**. [generator releases](https://github.com/apple/swift-openapi-generator/releases), [runtime releases](https://github.com/apple/swift-openapi-runtime/releases)
- 1.13.0 explicitly "Moved to Swift 6 language mode" ([PR #867, in the 1.13.0 notes](https://github.com/apple/swift-openapi-generator/releases/tag/1.13.0)).
- Framework-agnostic by design: it generates against a transport protocol, and the server transport is a separate small package per framework.

**Two limitations that bite this project specifically**, from the project's own [Supported OpenAPI features](https://github.com/apple/swift-openapi-generator/blob/main/Sources/swift-openapi-generator/Documentation.docc/Articles/Supported-OpenAPI-features.md):

1. **`security` is unsupported** (`- [ ] security` under "OpenAPI Object"). Ticket 07's bearer-token model would not be expressed in generated code at all — auth stays entirely in framework middleware, and the OpenAPI document's security scheme becomes documentation only.
2. Structured decoding covers `application/json` **and any content type ending in `+json`**, so ticket 06's `application/merge-patch+json` bodies do get generated `Codable` types. But the generator has no notion of Merge Patch's three-state semantics — a generated optional property cannot distinguish "absent" from "explicit null", which is exactly the distinction ticket 06's `Patchable<T>` exists to make. Expect to hand-write or post-process the patch DTOs either way.

**The server-transport packages are where the two frameworks diverge sharply:**

| Transport | Latest release | Last commit | `swift-tools-version` |
| --- | --- | --- | --- |
| [vapor/swift-openapi-vapor](https://github.com/vapor/swift-openapi-vapor) | **1.2.0, 2026-09-02** (1.1.0 on 2026-07-24) | 2026-07-31 | `6.1`, with `StrictConcurrency=complete` and `ExistentialAny` |
| [hummingbird-project/swift-openapi-hummingbird](https://github.com/hummingbird-project/swift-openapi-hummingbird) | **2.0.1, 2024-09-30** | **2025-05-08** | `5.10` |

([vapor transport Package.swift](https://github.com/vapor/swift-openapi-vapor/blob/main/Package.swift), [hummingbird transport Package.swift](https://github.com/hummingbird-project/swift-openapi-hummingbird/blob/main/Package.swift), release/commit data from the GitHub API.)

Both are thin adapters — a few hundred lines mapping the runtime's request/response types onto the framework's — so the Hummingbird one being stale is a fork-and-maintain risk rather than a blocker. But it is a real asymmetry if OpenAPI-first generation is on the table for ticket 04.

### Other SSWG packages that would be in this server's dependency graph

All verified via GitHub releases API on 2026-09-07.

| Package | Latest | Relevance here |
| --- | --- | --- |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | **2.12.0, 2026-08-18** | Ordered startup/graceful shutdown across HTTP server + DB pool + background sync tasks. SSWG **incubating**. Native to Hummingbird (`ApplicationProtocol: Service`); Vapor 4 does not use it, Vapor 5 alpha does. |
| [swift-log](https://github.com/apple/swift-log) | **1.15.0, 2026-08-05** | SSWG **graduated**. Both frameworks use it; `Logger` is threaded through `RequestContext` / `Request`. |
| [swift-metrics](https://github.com/apple/swift-metrics) | SSWG **graduated** | Both frameworks depend on it. |
| [swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing) | — | Both frameworks depend on it (HB `from: 1.3.0`, Vapor 5 `from: 1.1.0`). |
| [apple/swift-configuration](https://github.com/apple/swift-configuration) | **1.2.0, 2026-03-05** | Notable: **both** Vapor 5 alpha and Hummingbird 2 now depend on it (behind traits), so it is becoming the common config layer rather than each framework's own `Environment`. |
| [vapor/postgres-nio](https://github.com/vapor/postgres-nio) | **1.33.1, 2026-07-20** | The mature server-side Postgres driver; framework-independent. Relevant to tickets 05/08 rather than 04. |
| [async-http-client](https://github.com/swift-server/async-http-client) | SSWG **graduated** | Client-side; both frameworks depend on it. |

The practical point: **the observability, config and lifecycle layer is now shared**, not framework-specific. Whichever framework is chosen, the server's `swift-log` / `swift-metrics` / ServiceLifecycle wiring looks similar, which lowers the cost of the choice.

---

## Linux deployment: what is common to all three

Framework choice barely moves the Linux story. What actually varies is how much Foundation you drag in.

- **Toolchain.** swift.org ships official Linux toolchains for 6.3.3 on x86_64 and aarch64, plus official Docker images and a **Swift SDK for Static Linux** ([swift.org/install/linux](https://www.swift.org/install/linux/)).
- **The mainstream path is dynamic-Swift-runtime-free but glibc-linked.** Both official templates do exactly the same thing: build in `swift:6.3-noble`, run in `ubuntu:noble`, `swift build -c release --static-swift-stdlib -Xlinker -ljemalloc`, copy `swift-backtrace-static`, and install only `libjemalloc2` + `ca-certificates` + `tzdata` at runtime ([Vapor template](https://github.com/vapor/template/blob/main/Dockerfile), [Hummingbird template](https://github.com/hummingbird-project/template/blob/main/Dockerfile)). Runtime image is a normal Ubuntu 24.04 LTS base — fine for a self-hosted target, not a distroless/scratch story.
- **The fully-static path is the Static Linux SDK (musl).** `swift build --swift-sdk x86_64-swift-linux-musl` (or `aarch64-...`) produces a binary with *"no external dependencies at all (not even the C library)"*, portable across distributions and installable by copying ([Static Linux getting started](https://www.swift.org/documentation/articles/static-linux-getting-started.html)). Caveats from that same page: **no dynamic linking at all — `dlopen()` does not work**; packages that `import Glibc` need a Musl variant; the SDK bundles only common C deps (libxml2, zlib, curl) and anything else must be integrated by hand; binaries are larger. Foundation and SwiftNIO are called out as working.
- **Foundation is the variable.** Vapor's template comments out `libcurl4` and `libxml2`, needed only if something imports `FoundationNetworking` or `FoundationXML`. Hummingbird states the goal of limiting exposure to `FoundationEssentials`; Vapor 5 has a "Prefer FoundationEssentials" change in its alpha.2 notes ([alpha.2 notes](https://github.com/vapor/vapor/releases/tag/5.0.0-alpha.2)). Bare NIO keeps Foundation entirely optional behind `NIOFoundationCompat`. **For a `--swift-sdk musl` static build, less Foundation is strictly easier.**

---

## Comparison

| | **Vapor 4** | **Vapor 5** | **Hummingbird 2** | **Bare SwiftNIO** |
| --- | --- | --- | --- | --- |
| Latest release | 4.122.1 (2026-08-25) | 5.0.0-alpha.2 (2026-08-11) | 2.26.0 (2026-07-29) | 2.102.0 (2026-09-01) |
| Stability | Stable, legacy line | **Alpha** | Stable | Stable, SemVer-disciplined |
| SSWG level | Graduated | Graduated | Incubating | Graduated |
| License | MIT | MIT | Apache 2.0 | Apache 2.0 |
| Stars / open issues / open PRs | 26.2k / 80 / 26 (whole repo) | — | 1.9k / 18 / 6 | 8.5k / 186 / 108 |
| Commits, last 90d | 71 (on `main`, i.e. v5 work) | — | 36 | 49 |
| Swift 6 language mode | Yes (tools 6.0) | Yes (tools 6.2 at tag; **6.4 on `main`**) | Yes (tools 6.1 + 3 upcoming features) | Yes (tools 6.1) |
| `Sendable` posture | `Request`/`Application: Sendable`; all Sendable issues closed | Rewritten for it | `Request` is a `Sendable` struct; all handlers `@Sendable async` | `NIOAsyncChannel<Inbound: Sendable, Outbound: Sendable>: Sendable` |
| `EventLoopFuture` in public API | Yes, still load-bearing | Reduced | **None — removed in v2** | Yes, it *is* the model |
| Request body | Collated by default | — | **Streamed by default** (`AsyncSequence`) | `ByteBuffer` via pipeline |
| DI / per-request state | Extend `Request` via storage | Controller macros | Generic `RequestContext` + constructor injection | Yours to build |
| ServiceLifecycle | No (branch only) | Yes (2.6.3) | **Yes — `ApplicationProtocol: Service`** | No |
| WebSocket | Yes, callback-based (`ws.onText { }`) | `websocket-kit` dep | Yes, **`for try await` over `inbound`**, with router+middleware on upgrade | `NIOWebSocket`, frame-level |
| SSE | **No** — [PR #2960 open since 2024](https://github.com/vapor/vapor/pull/2960); async body streaming exists | branch in flight | Not in core; untagged `SSEKit` + official example; `ResponseBody(asyncSequence:)` | Hand-rolled |
| OpenAPI transport | `swift-openapi-vapor` **1.2.0 (2026-09-02)**, tools 6.1 | — | `swift-openapi-hummingbird` **2.0.1 (2024-09-30)**, last commit 2025-05, tools 5.10 | n/a |
| Linux template | Yes, `swift:6.3-noble` → `ubuntu:noble` | — | Yes, same shape | n/a |
| Batteries | Leaf, Fluent, sessions, validation, console | Same, behind package traits | Modular, separate repos, several untagged | None |

---

## Considerations for the decision (ticket 04)

Framing only — the call belongs to [ticket 04](../issues/04-choose-server-framework-concurrency-model.md).

**1. The Vapor 4 / Vapor 5 fork is the central timing risk.** Vapor 4 is clean under Swift 6 and will be maintained, but `main` has moved on and Vapor 4's internals are the ones Vapor 5 exists to replace. Vapor 5 is alpha, its `main` requires an unreleased toolchain (`swift-tools-version:6.4` vs released 6.3.3), and its HTTP server dependency is a self-declared work-in-progress at 0.1.0 pinned by SHA. Picking Vapor means picking a side of that fork and owning the migration, or the wait. Hummingbird has no equivalent pending discontinuity.

**2. "Compiles under strict concurrency" vs "shaped like structured concurrency" are different bars, and this project has stated the higher one.** All three compile in Swift 6 language mode. Only Hummingbird 2 has *removed* the event-loop API surface (`"Hummingbird v2 is now exclusively Swift concurrency based. All EventLoop based APIs have been removed."`). If the map's "maximize structured concurrency across every surface" is meant literally, that distinction is the finding to weigh; if "clean under strict concurrency" is the real requirement, Vapor 4 clears it.

**3. Dependency injection style interacts directly with the shared-Core architecture.** [ADR 0002](../../docs/adr/0002-monorepo-shared-core-package.md) puts domain logic in a Core package consumed by Server, CLI and MCP. Hummingbird's `RequestContext` + constructor-injected controllers pushes you toward "handlers are thin adapters over Core services (likely actors)", which is what the CLI and MCP executables will do anyway. Vapor's `Request` storage / `Application` services pattern makes the server's composition root look less like the other two surfaces. Neither is disqualifying; it is a consistency-across-three-executables question.

**4. Real-time is a *future* thread, so weigh WebSocket/SSE as migration cost, not v1 cost.** v1 is pull-based ([ADR 0001](../../docs/adr/0001-self-hosted-single-tenant-offline-sync.md)); both frameworks can stream a response body today. The differences that would matter later: Hummingbird's WebSocket upgrade runs through a router with middleware, so ticket 07's token auth applies unchanged, and its inbound stream is an `AsyncSequence`. Vapor 4's is a callback API with no SSE support merged in two years. Neither is a v1 blocker.

**5. Community size vs bus factor is a genuine trade, not a tiebreaker.** Vapor: 26.2k stars, many contributors, the most Stack Overflow/forum answers, SSWG **graduated**, and by far the most existing self-hosted-Swift prior art. Hummingbird: 1.9k stars, SSWG **incubating**, a tidy 18-issue backlog, and effectively one dominant maintainer. For a self-hosted tool that must be maintainable by a small team for years, "which one can I get an answer about at 2am" and "what happens if the maintainer stops" point in opposite directions.

**6. If OpenAPI-first generation is on the table, the transport packages are lopsided.** `swift-openapi-vapor` shipped 1.2.0 on 2026-09-02 in Swift 6 mode; `swift-openapi-hummingbird` last shipped in September 2024 and last saw a commit in May 2025 at `swift-tools-version: 5.10`. Both are thin, so forking is viable — but note also that the generator does **not** support `security` and cannot express Merge Patch's absent-vs-null three-state, so ticket 06's contract would need hand-written patch DTOs and middleware-based auth regardless of framework.

**7. Bare NIO is a real option only if the framework layer is the thing you want to own.** Ticket 06 already specifies routing, patch semantics, cursor pagination, `expand`, and 410-vs-404 — that is most of a framework's job, described. NIO gives the cleanest Foundation-free static Linux binary and the least churn risk (no NIO 3 on the horizon), at the cost of building and maintaining routing, `Codable` binding and middleware in-house, in a pipeline model that is not itself structured-concurrency-shaped.

**8. Linux deployment barely differentiates.** Both frameworks ship the same two-stage `swift:6.3-noble` → `ubuntu:noble` Dockerfile with `--static-swift-stdlib`. The only real lever is Foundation exposure if you later want a fully-static musl binary — where Hummingbird's FoundationEssentials intent and bare NIO's optional `NIOFoundationCompat` are marginally ahead of Vapor 4. This should not drive the choice.
