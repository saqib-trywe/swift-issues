# v1 Architecture

## Destination

A locked technical spec — domain model, HTTP API contract, sync/concurrency architecture, auth model, and tech stack per surface (Server, macOS/iOS/iPadOS apps, CLI, MCP interface) — for a lightweight, self-hosted, multi-user, offline-first issue tracker written in Swift (latest released version, latest-released-only platforms). Ready to hand off to a separate implementation effort; this map does not build the thing.

## Notes

- Domain: see [CONTEXT.md](../../CONTEXT.md) for the glossary (Instance, Project, Issue, Issue Key, Status, Priority, Label, Reporter, Assignee, Due Date, Comment, Member/Admin).
- Every session should call the Skill tool for **grilling** (default ticket resolution mode) and **domain-modeling** (keep `CONTEXT.md` and `docs/adr/` updated as terms and hard-to-reverse decisions crystallize).
- Research findings live in [research/](research/); tickets carry their own resolutions inline.
- Standing architectural decisions locked before ticketing — see [ADR 0001](../../docs/adr/0001-self-hosted-single-tenant-offline-sync.md) and [ADR 0002](../../docs/adr/0002-monorepo-shared-core-package.md) for full rationale:
  - Self-hosted, single-tenant per Instance; multi-user with Member/Admin roles only, no granular permissions.
  - Offline-first clients, server-authoritative sync, last-write-wins per field (no CRDT).
  - Pull-based sync only in v1 (foreground/manual/background-fetch refresh); no push notifications yet.
  - Single SwiftPM monorepo: shared Core package + Server/CLI/MCP executable targets, plus a separate Xcode project/workspace for the SwiftUI apps.
  - v1 feature floor: Project → Issue (title, description, status, assignee, reporter, priority, labels, due date) → Comment; fixed status set; basic search/filter.
  - Swift: latest released version. Platforms: latest-released-only, no backward-compatibility shims. Maximize structured concurrency (async/await, actors) across every surface.

## Decisions so far

**[01 Domain model v1](issues/01-domain-model-v1.md) — resolved.** Six entities: User, Project, Issue, Label, IssueLabel, Comment. Full field lists, invariants and permissions in the ticket's resolution; vocabulary in [CONTEXT.md](../../CONTEXT.md). Headlines:

- **Identity** ([ADR 0003](../../docs/adr/0003-identity-and-conflict-resolution.md)): client-generatable UUIDv7 primary keys, plus a separate server-assigned Issue Key (`PROJ-142`) that is null until first sync, monotonic per Project, and never reused.
- **Conflict arbitration** ([ADR 0003](../../docs/adr/0003-identity-and-conflict-resolution.md)): the **server's receipt timestamp** decides, not client wall clocks. Per-field for Issue's six mutable scalars, per-record for Comment. Deletion is terminal and beats a concurrent edit. Nothing is hard-deleted; tombstones are kept indefinitely.
- **Labels** are a managed, project-scoped entity whose ids are UUIDv5-derived from (project, name) so concurrent offline creates converge; membership is an **IssueLabel link record**, not a set-valued field, so concurrent adds both survive.
- **Offline write failures** ([ADR 0004](../../docs/adr/0004-offline-write-failure-contract.md)): causal (topological) replay order, strict server-side referential integrity, and **quarantine without head-of-line blocking** for rejected operations.
- **Fixed enums**: Status (todo / inProgress / done / cancelled, each open or closed), Priority (none…urgent, defaulting to none), Role (member / admin) — all **leniently decoded** so a server upgrade can't break lagging clients.
- **Text** is Markdown source, rendered by clients, never by the server. `dueDate` is a timezone-free calendar date.

**[06 HTTP API contract](issues/06-http-api-contract-design.md) — resolved.** Full contract in the ticket's resolution; shape decisions in [ADR 0005](../../docs/adr/0005-two-write-paths-one-concurrency-model.md). Headlines:

- **Two contracts, one concurrency model**: a REST resource API (`/api/v1/...`) for CLI/MCP/scripts, and a narrow sync pair (`sync/push`, `sync/pull`) for the offline-first apps. Both generated from the same Core DTOs — that shared origin is the only thing stopping them drifting.
- **No `ETag`/`If-Match` anywhere**, deliberately: optimistic concurrency on REST plus last-write-wins on sync would mean the semantics you get depend on which client you used.
- **Sync push returns 200 with per-operation results** in three outcomes — `applied`, `rejected` (quarantine), `superseded` (lost LWW, carries the winning record). `superseded` is what makes ADR 0001's "surface the losing edit" implementable.
- **Sync pull is one unified causal stream** with an opaque server-sequence watermark (not a timestamp) and first-class tombstones; it echoes the client's own writes back so a client that mis-tracked a write self-heals.
- **All mutation is JSON Merge Patch** (RFC 7386), requiring a three-state `Patchable<T>` in Core; only keys present in a PATCH get their field timestamps bumped, which is what per-field LWW needs.
- `PUT /issues/{id}` is create-only and idempotent (409 on conflicting re-create); no `POST /issues`. Issue Keys resolve as URLs (`/issues/PROJ-142`). Deleted resources are **410 Gone**, not 404. Cursor pagination, flat filter params, opt-in `?expand=`.

**[07 Auth model](issues/07-auth-model-design.md) — resolved.** Full model in the ticket's resolution; rationale in [ADR 0006](../../docs/adr/0006-auth-model.md). Headlines:

- **Local email + password only** (no OIDC/SSO in v1), Argon2id, min 12 chars, no rotation or composition rules.
- **Opaque 256-bit tokens stored hashed server-side, no JWT and no refresh tokens** — one server with its database already open gains nothing from JWT but loses revocation. 60-day idle expiry renewed on use, 1-year absolute cap; multiple devices, individually revocable.
- **Personal access tokens** for CLI and MCP, same permissions as their owner, with a `kind` (human vs agent) so Admins can spot agents. **No web UI exists**, so they're minted from the macOS app, with `issues auth token create` as the bootstrap path.
- **First-Admin bootstrap**: one-time token printed to stdout on first start against an empty database, plus env-var seeding for scripted deploys.
- **No email dependency.** Reset is an Admin action; the consequence is that a sole Admin can lock themselves out, so `issues-server admin reset-password` on the host is a hard prerequisite.
- **Role enforcement at both layers**: declarative role requirements on routes, record-dependent ownership checks in services.
- **Auth failure never quarantines a write** — a 401 mid-sync preserves the queue and asks for re-login.
- **Per-account login throttling is a deliberate exception** to the no-rate-limiting rule, since an unauthenticated attacker is not an identifiable team member.

**[11 CLI command surface & auth flow](issues/11-cli-command-surface-auth-flow.md) — resolved.** No ADR; ergonomics over already-recorded decisions. Headlines:

- `issues <noun> <verb>` with **`issue` as the implied default noun** — `issues list`, `issues close PROJ-142`. Convenience verbs (`close`, `start`, `cancel`, `assign`) kept as sugar over `edit`.
- **`--json` is the stable interface; the human table is not**, and says so in `--help`. `--quiet` prints bare Issue Keys for piping.
- **`--unset <field>`** is the CLI's expression of Merge Patch's three states; `none` is deliberately not overloaded for clearing, since it is already a *filter* token.
- `$EDITOR` for Markdown bodies, git-style, with `--description -` for stdin.
- Documented exit codes including **3 (not found) distinct from 6 (gone)**, so ticket 06's 410-vs-404 decision actually reaches a user. Never prompts when stdin isn't a TTY.
- **Admin commands are shown in help and rejected at call** — hiding them would make `--help` require a network round trip.
- **The CLI is online-only with no cache.** A cache would be a second sync implementation in a surface with no UI for quarantine or superseded edits. Accepted cost: `issues list` fails on a plane while the Mac app beside it works.

Resolving this surfaced a gap **backfilled into ticket 07**: throttled auth now returns 429 with `Retry-After`, and login failures must not distinguish "no such account" from "wrong password".

**[12 MCP tool surface & agent auth](issues/12-mcp-tool-surface-agent-auth.md) — resolved.** Full surface in the ticket; rationale in [ADR 0007](../../docs/adr/0007-agents-are-not-users.md). Headlines:

- **Agents are a distinct actor class, not Users.** Agent-kind tokens carry a fixed, non-configurable reduced profile (Issues/Comments/Labels read-write; never user management, delete or administration) regardless of their owner's role, plus an `agent-readonly` variant. Not a scope system — nothing is configurable.
- **No destructive MCP tools at all.** Ten fine-grained tools; `status: cancelled` is an agent's reversible "make it go away".
- **`via: human | agent` added to Issue and Comment** — this deliberately amended the resolved ticket 01 model, because the field cannot be backfilled later.
- **Rate limiting applies to agent tokens only** (60/min, burst 120) — resolving the exception ticket 06 flagged.
- **List tools return a compact projection, knowingly deviating** from ticket 11's raw-payload rule: agents have a hard context budget that CLI users don't.
- **stdio transport, local process**, reusing the CLI's credential conventions; ships in the distribution but is not operator-deployed.

**[13 Testing & CI strategy](issues/13-testing-ci-strategy.md) — resolved.** Added after the original twelve; it was the one gap flagged as unspecified throughout. No ADR (process, not architecture).

- **TDD**, Swift Testing, per-target coverage floors (Core 90%, server 80%, CLI/MCP 70%, view models 80%, **view bodies ungated**) plus a **no-regression rule**, which does more real work than any absolute number.
- **CI on GitHub Actions `macos-latest`** — Linux containers are unavailable to us (ADR 0010), and **macOS minutes bill at 10× on a private repo**. That cost is the concrete price of the macOS-only decision, and it is why the suite has a **time budget** (unit < 60s, full CI < 10 min).
- **The sync engine is tested by a deterministic in-memory harness** plus **property-based convergence testing** across random operation orders. Highest-value decision in the ticket: this bug class cannot be found by hand.
- **A contract test asserts REST and sync push produce identical state.** [ADR 0005](../../docs/adr/0005-two-write-paths-one-concurrency-model.md) rests its whole no-drift argument on shared DTOs, which is a hope until something checks it.
- **`Patchable<T>` is written test-first, before anything depends on it** — absent-vs-null is what ADR 0005 flagged as needing to be right exactly once.
- Testing turned up a **second, unplanned argument for variant C**: `SyncStatusView` exists once, so the five sync surfaces need five rendering tests rather than ten across two drifting implementations.

**[10 Native app scope & UX](issues/10-native-app-scope-ux.md) — resolved.** No ADR — UI structure over decisions already recorded. Prototype kept at [prototype/PROTOTYPE-issue-list-detail.html](prototype/PROTOTYPE-issue-list-detail.html).

- **Variant C, adaptive core**: shared components and one view model, composed differently per platform. Rejected the unified layer (an iPad app on a desktop) and the fully divergent one.
- **What decided it was the five required sync surfaces**, not aesthetics — advisory pre-push conflict warning, quarantine, superseded-by-deletion, full-resync progress, needs-re-authentication. They are required for the sync guarantees to hold, and full divergence means designing each one **twice**, which is where they would drift into a correctness problem.
- **iPad takes the macOS composition at touch sizes**, not the iPhone one — but not the Mac's token/session administration.
- **macOS alone carries token management and the device/session list**, because there is no web UI.
- Divergence is confined to layout container, input affordances and the Mac-only admin surfaces. Filtering, search, sort semantics, copy and every sync surface are shared.

**[09 Deployment model](issues/09-deployment-model.md) — resolved.** [ADR 0010](../../docs/adr/0010-macos-single-process-server.md) amended by it.

- **Rootless, per-user install**: everything under `~` (`~/Library/Application Support/Issues/`, `~/Library/Logs/Issues/`, `~/.local/bin/`), so no service account and no admin password. Signed and notarized user-domain `.pkg`; macOS 26, Apple silicon only.
- **`LaunchAgent`, not `LaunchDaemon`** — follows per-user convention, at a real cost: the server runs only inside a login session, so **an unattended reboot leaves the Instance down until someone logs in**. Mitigated at OS level (automatic login + restart after power failure), and the docs must say so.
- **Backup is a command, not a file copy** — this corrected ADR 0010, which claimed otherwise. WAL means three files and a live one holds committed data in the `-wal`; `cp` yields a corrupt or stale backup that looks fine until you need it. `issues-server backup` uses SQLite's online backup API.
- **Restore forced a change to the sync protocol.** Rewinding the sequence would leave clients holding a high watermark silently cut off forever with no error. The watermark is now **`epoch:seq`**; restore mints a new epoch; a stale epoch forces a full resync. **Amended into tickets 06 and 08.**
- Bind to `127.0.0.1` by default so cleartext exposure requires a deliberate act; Caddy documented as the reverse proxy. Config is TOML with `ISSUES_*` overrides (env-only is wrong under launchd). Bootstrap token written to a self-deleting `0600` file rather than grepped from a log. Auto-migration on startup, **preceded by an automatic backup**.

**[08 Sync protocol & conflict handling](issues/08-sync-protocol-conflict-handling.md) — resolved.** No new ADR — semantics inside envelopes ADRs 0003/0004/0005 already fixed — but it **amended [ADR 0005](../../docs/adr/0005-two-write-paths-one-concurrency-model.md)** and **corrected ticket 04**.

- **Watermark is a change-cursor table** (one upserted row per entity), not an append-only log. Guarantee: **at-least-once, never missed** — a row only moves ahead of the cursor.
- **`superseded` is far narrower than it sounded**: under receipt-time arbitration the last arrival always wins, so it fires only when the target is **tombstoned**. ADR 0005 amended to say so.
- **The stale-clobber consequence is accepted and pushed to the client**: a three-day-old offline edit does clobber newer work, and the *only* warning is an advisory client-side check before pushing. Server-side detection would be optimistic concurrency, which ADR 0005 rejected — moving it there requires amending two ADRs explicitly, not drifting into it.
- **One transaction per operation; a batch is a round-trip optimisation, not an atomicity boundary.** The shutdown guarantee is **idempotent replay**, not batch atomicity. This corrected ticket 04's wording, which had claimed the opposite.
- **Pull ordering breaks referential integrity by design**: `seq` is change order, so a comment can arrive hundreds of pages before its issue. The client therefore **does not enforce foreign keys** on sync-populated tables; orphans are stored and simply not displayed. Anyone "fixing" this breaks first sync.
- Applying a page and advancing the watermark are **one transaction**. `opId` dedupe records retained **indefinitely**. Pull application never touches the pending queue; a full resync never clears it.

**[04 Choose server framework & concurrency model](issues/04-choose-server-framework-concurrency-model.md) — resolved.** Rationale in [ADR 0009](../../docs/adr/0009-hummingbird-and-server-concurrency.md) and [ADR 0010](../../docs/adr/0010-macos-single-process-server.md).

- **Hummingbird 2.** Decisive argument was consistency: Vapor 5's `main` needs `swift-tools-version:6.4` while released Swift is 6.3.3, and ticket 05 chose OS 26 over 27 for exactly that reason. Vapor 4 is stable and clean but is the *legacy* line whose EventLoop internals Vapor 5 exists to replace. Hummingbird 2 is the only candidate both **stable and structured-concurrency-native**. Accepted cost: 1.9k stars vs 26.2k, SSWG incubating, one dominant maintainer.
- **Thin stateless handlers over `Sendable` Core services; actors only for genuinely shared mutable state** (rate-limit buckets, throttle counters, bootstrap token). Actor-per-service was rejected deliberately — it serialises throughput that never needed it and adds reentrancy bugs at every `await`.
- **Server database: SQLite via GRDB** — an unticketed gap found while resolving this. Chief reason is technical, not operational: with concurrent writers a monotonic watermark can **commit out of order**, letting a client skip a change permanently. SQLite in WAL serialises writers so the window cannot open. Also one storage library across client and server.
- **Background work is ServiceLifecycle periodic tasks in a task group** — no job queue, no cron, no external scheduler. Graceful shutdown drains in-flight requests.
- **The server is macOS only** — no Linux build, no container, no Linux CI. This narrows who can ever run the software to people with a spare Mac, which is the most likely reason to revisit it, and is recorded as deliberate.

**[05 Choose local storage & offline queue](issues/05-choose-local-storage-offline-queue.md) — resolved.** Full design in the ticket; rationale in [ADR 0008](../../docs/adr/0008-grdb-client-storage-and-offline-queue.md). The technology was chosen **last**, after four inputs that determine it:

- **Minimum deployment target is OS 26** — applying the latest-*released*-only policy literally while 27 is imminent but unreleased. This is the deciding input, and it is why the answer is not SwiftData.
- **The strict-concurrency gate means "the compiler proves data-race safety"**, not "it builds in Swift 6 mode". This eliminates hand-rolled SQLite, which passes only by assertion. **The same reading now applies to ticket 04.**
- **Linux reuse of the client store is not a requirement** — CLI and MCP are online-only and stateless, so storage is an Apple-only module. (Superseded in scope by [ADR 0010](../../docs/adr/0010-macos-single-process-server.md): nothing in the system targets Linux any more.)
- **Replay ordering is an application property** — a topological sort in Swift in Core, not a recursive CTE, because ADR 0004's causal ordering is a domain contract that should be testable without a database.

The choice is **GRDB**, on atomicity (`write { }` *is* the transaction, versus SwiftData's per-call-site convention) and partial indexes (how quarantine-without-head-of-line-blocking is actually expressed). **One database file** for replica and queue, so local mutation + enqueue is one transaction; `DatabasePool` in WAL. Cost accepted: no `@Query`, about a day of `@Observable` wrapper, and single-maintainer bus-factor risk. **This would likely have gone the other way on OS 27** — recorded as schedule-dependent, not a verdict on SwiftData.

Queue: `pending_operation` with a **partial index on `state = 'pending'`** (the head-of-line-blocking guarantee as an index, not a convention), Merge-Patch-shaped payloads, **derived rather than stored** dependencies, coalescing within one entity's unsent run. Only the base record is stored; display is base + pending applied on read. A tombstone for an entity with pending edits **drops them as superseded-by-deletion rather than quarantining** — there is nothing to retry against.

**[03 Local storage research](issues/03-local-storage-research.md) — resolved.** Findings in [research/03-local-storage-landscape.md](research/03-local-storage-landscape.md) (428 lines, primary sources cited, several facts verified directly on the machine rather than from docs). No recommendation made — it feeds ticket 05. Shortlist: **SwiftData, GRDB, hand-rolled SQLite**; Core Data direct and SQLite.swift assessed and dropped. The axes that should move ticket 05:

- All three shortlisted pass Swift 6 strict concurrency **but not in the same way** — GRDB compiler-enforced, SwiftData enforced via a non-`Sendable` `ModelContext`, hand-rolled only *by assertion*. Ticket 05 must say which reading of the hard gate it means.
- **SwiftData has no raw-SQL escape hatch at all**, so ADR 0004's topological replay ordering and quarantine's transitive closure become Swift-side graph walks rather than recursive CTEs — and there is no path to FTS5 later without changing storage layers.
- SwiftData's change-observation weakness is **OS 27-only API**, so the storage choice is **coupled to the minimum deployment target**; the other two are unaffected.
- SwiftData wins outright on UI velocity (`@Query`), which the ticket should price rather than dismiss.
- **SwiftData and Core Data cannot run on Linux** — decisive if shared-Core reuse in CLI/MCP/CI is a real requirement rather than a hypothetical.

**[02 Server framework research](issues/02-server-framework-research.md) — resolved.** Findings in [research/02-server-framework-landscape.md](research/02-server-framework-landscape.md) (315 lines, primary sources cited). No recommendation — it feeds ticket 04. Baseline: **Swift 6.3.3** (2026-06-30). The axes that should move ticket 04:

- **Vapor has forked and neither side is settled.** `main` is Vapor 5 (`5.0.0-alpha.2`), declaring `swift-tools-version:6.4` — *newer than released Swift* — and depending on a work-in-progress package pinned by commit SHA; Vapor 4 (`4.122.1`) continues on a `vapor4` branch. Hummingbird has no equivalent pending discontinuity. **This is a timing problem, not a capability problem.**
- **Strict concurrency is not the discriminator — concurrency *shape* is.** All three build in Swift 6 language mode, and Vapor 4 is genuinely clean. But Vapor 4 still documents an event-loop model with `EventLoopFuture` load-bearing, while Hummingbird v2 removed all EventLoop-based APIs outright. Given the project's "maximise structured concurrency" policy, that is the finding to weigh.
- **The OpenAPI transport packages are badly lopsided** — `swift-openapi-vapor` shipped 1.2.0 on 2026-09-02; `swift-openapi-hummingbird` last released 2024-09-30, last commit 2025-05-08, still tools-version 5.10. Separately the generator supports neither `security` nor Merge Patch's absent-vs-null, so **ticket 06's contract needs hand-written patch DTOs and middleware auth regardless of framework**.
- **Hummingbird maps onto ADR 0002 more directly, at a bus-factor cost.** Generic `RequestContext` plus constructor-injected controllers makes handlers thin adapters over Core actors — the same shape the CLI and MCP executables take — and ServiceLifecycle graceful shutdown is its default idiom. Against that: 1.9k stars vs Vapor's 26.2k, SSWG *incubating* vs *graduated*, one dominant maintainer.
- **Linux barely differentiates** (both official templates are the same shape), and **real-time is a migration-cost question, not a v1 one**: Hummingbird's WebSocket is `for try await` with middleware on the upgrade request (so ticket 07's token auth applies unchanged); Vapor 4's is callback-based and its SSE PR has been open since 2024.

## Not yet specified

- Push notifications / real-time live updates (APNs, WebSockets) — deferred; will need its own design once pull-based v1 ships and proves insufficient.
- Search/filter depth beyond "basic" (full-text search engine vs simple field filters) — not yet sharp enough to ticket.
- Testing/CI strategy across five surfaces — not yet specified.
- Label rename/merge/delete administration — the model supports rename, but no UI or API for tidying up label sprawl is specified yet.

## Out of scope

- Epics, sprints, boards, story points, workflow automation, user-configurable workflows — cut to keep v1 lightweight; Project/Issue/Comment with a fixed status set is the intended v1 ceiling.
- Multi-tenant hosted SaaS (multiple isolated orgs/billing behind one server) — this is a self-hosted, single-team-per-Instance tool by design.
- CRDT-based conflict merge — superseded by the simpler last-write-wins model in [ADR 0001](../../docs/adr/0001-self-hosted-single-tenant-offline-sync.md); would return only if v1 experience shows last-write-wins insufficient, and then as a fresh effort.
- **Attachments / file upload** — cut in ticket 01: a whole subsystem (blob storage, upload progress, offline binary caching, backup weight), not a field. Expected to be v1's most-missed absence; the API contract leaves room for it.
- **Issue-to-Issue links** (parent/child, blocks/blocked-by) — cut in ticket 01; cycle detection and graph UI, and offline clients can create cycles independently. Plain-text Issue Key mentions are the v1 escape hatch.
- **Moving an Issue between Projects** — cut in ticket 01; it would make Issue Keys mutable, and everything downstream assumes they are not.
- **Multi-assignee**, configurable priorities/statuses, rich-text/WYSIWYG editing — cut in ticket 01.
- **Hybrid logical clocks** for conflict ordering — considered and rejected in [ADR 0003](../../docs/adr/0003-identity-and-conflict-resolution.md) as disproportionate; revisit only if users report losing edits they genuinely made first.
- **`ETag`/`If-Match` optimistic concurrency** — considered and rejected in [ADR 0005](../../docs/adr/0005-two-write-paths-one-concurrency-model.md); a reviewer will expect it, so the rejection is recorded rather than left to be rediscovered.
- **A filter-expression DSL** on the API — flat query params only; a DSL is a parser and an injection surface.
- **`POST /issues` with a server-allocated id** — impossible offline; `PUT` with a client-generated UUIDv7 replaces it.
- **Rate limiting** — none in v1 beyond hard payload/batch/page caps. MCP agents are the flagged exception, on ticket 12.
- **OIDC / SSO** — cut in ticket 07 as a genuine lift a single-team tracker doesn't need to launch; expected to be the first ask from any corporate self-hoster, so the model must not assume every User has a password.
- **JWT and refresh tokens** — considered and rejected in [ADR 0006](../../docs/adr/0006-auth-model.md); a reviewer will expect them, so the rejection is recorded.
- **SMTP / email delivery** — no email dependency anywhere in v1.
- **Linux, containers and Docker** — cut in ticket 04 ([ADR 0010](../../docs/adr/0010-macos-single-process-server.md)); the server runs on macOS under launchd. The CLI's Linux credential fallback survives as incidental, not supported.
- **Postgres** — considered and rejected in [ADR 0010](../../docs/adr/0010-macos-single-process-server.md); the deciding reason is out-of-order watermark commits under concurrent writers, not operational preference.
- **Actor-per-service on the server** — rejected in [ADR 0009](../../docs/adr/0009-hummingbird-and-server-concurrency.md); recorded so nobody "fixes" the stateless services into actors.

## Status: spec complete — implementation begun (2026-09-08)

**Thirteen tickets resolved.** Ten ADRs, three amended in place rather than left to disagree: ADR 0005 (by ticket 08), ADR 0010 (by ticket 09), ticket 01's model (by ticket 12). Ticket 04's batch-atomicity wording was corrected by ticket 08, and ticket 09's watermark change pushed back into 06 and 08.

Repo initialised; the spec is committed as its first commit.

### Repo layout

**SwiftPM package at the repository root** — see [ADR 0002](../../docs/adr/0002-monorepo-shared-core-package.md). `Core` library plus `Server`, `CLI` and `MCP` executables, a `TestSupport` target linked only by tests, and a separate Xcode workspace for the apps.

### Build order

1. **Core — `Patchable<T>` first, test-first.** Then the six entities, three leniently-decoded enums, validation.
2. **Server** — Hummingbird, GRDB migrations, change-cursor table, auth.
3. **CLI before the apps** — exercises the whole API contract with the least investment, so contract errors surface in a terminal rather than in SwiftUI.
4. **Apps** — sync engine and the five conflict surfaces; the expensive part, built on a contract already proven.
5. **MCP last** — thin over a well-proven API.

### Open threads

- **The CLI's Linux credential fallback** (ticket 11) is now incidental — nothing else targets Linux. Still needs an explicit call.
- **Stale offline edits clobber newer work silently on the server**, by design ([ADR 0005 amendment](../../docs/adr/0005-two-write-paths-one-concurrency-model.md)); the client-side advisory warning is the only mitigation.
- **A `LaunchAgent` server is down after an unattended reboot** until someone logs in ([ADR 0010](../../docs/adr/0010-macos-single-process-server.md)).
- **macOS 26 / Apple silicon only**, with OS 27 weeks away — [ADR 0008](../../docs/adr/0008-grdb-client-storage-and-offline-queue.md) records that the storage choice was schedule-dependent.
- Never ticketed: full-text search depth, attachments, push/real-time.

## Implementation progress (2026-09-09)

Repo initialised; SwiftPM package at root (ADR 0002). **Swift 6.3.3** is the global toolchain, pinned by `.swift-version`. `make test` / `make lint` / `make format`.

**Core is complete: 200 tests, 100% line coverage on the tested surface.**

| Piece | Notes |
| --- | --- |
| `Patchable` / `Settable` | Merge Patch's three states, and a two-type split so clearing a non-nullable field is unrepresentable |
| `Status` / `Priority` / `Role` / `Via` | Leniently decoded via `WireEnum`; unknown values preserved verbatim |
| `CivilDate` | Calendar day; **refuses** RFC 3339 instants |
| `ProjectKey` / `IssueKey` | ASCII-validated; Issue Key optional until first sync |
| `ID<Entity>` / `UUIDv7` / `UUIDv5` | Phantom-typed ids; v7 for time ordering, v5 for Label id derivation |
| Six entities + `JSONCoders` | Ticket 06 wire shape; encoder sorts keys for determinism |
| `Validation` | Pure rules only, on the way *in*; stable failure codes; 64KB counted in **bytes** |
| `HTTPRequest` / `HTTPResponse` / `APIError` | RFC 9457 problems; 410≠404, 401≠403, 429 carries `Retry-After` |
| Endpoints (all resources) | Pure request values; filters, cursor pagination, `expand` |
| `APIClient` + `FakeTransport` | One-method transport seam; token read per request |
| Sync envelopes | Push/pull, three outcomes, `epoch:seq` watermark, all 11 operation kinds round-tripped |
| `URLSessionTransport` | Deliberately thin; mappings are pure and tested, the network call is not |

### Server progress

Dependencies resolved as the research predicted: **Hummingbird 2.26.0, GRDB 7.11.1, NIO 2.102.0**. `Package.resolved` is committed (this package ships executables, so the graph is pinned). `Server` is a **library** with a thin `issues-server` executable on top, so it is testable without main-symbol clashes.

**Schema landed** (`AppDatabase`, migration `v1`): Core's six entities plus sessions, `change_cursor`, and a single `instance` row carrying the epoch. Two deliberate departures from Core's shapes:

- The `issue` row carries a timestamp **per mutable scalar**, which Core's `Issue` deliberately lacks — per-field last-write-wins is resolved server-side. **Columns rather than ticket 01's JSON sidecar**, because the comparison is a plain SQL predicate per field where a map needs `json_extract` on every write.
- `change_cursor` keys **one upserted row per entity** with a globally unique `seq`, so a row moves forward rather than accumulating history and two changes can never share a position.

WAL mode and foreign-key enforcement are tested explicitly: WAL serialising writers is why ADR 0010 chose SQLite, and foreign keys are how ticket 08's strict rejection of unknown references is enforced.

### Server: v1 HTTP surface complete

**397 tests. Core 99.14%, Server 98.35%**, both gated by `Scripts/check-coverage.py` (per-target floors plus a no-regression baseline).

| Piece | Notes |
| --- | --- |
| `AppDatabase` | SQLite via GRDB, WAL and foreign keys on in **both** on-disk and in-memory, so tests cannot create states production rejects |
| `ChangeCursor` | One upserted row per entity with a globally unique `seq`. Write-and-record is one transaction, with a test proving the cursor rolls back when the write throws |
| Sessions | Opaque 256-bit tokens stored as SHA-256. Not a KDF: a token has nothing to guess, so Argon2id would add latency per request and buy nothing. Argon2id arrives with login |
| Auth middleware | 401 ≠ 403 throughout. ADR 0007's agent profile enforced at the boundary: an Admin's agent is still not an admin |
| Project / Issue / Comment / Label | Full CRUD. Reporter, author and `via` come from the token, never the body |
| Filtering | OR-within / AND-across against real SQL. Keyset cursors, with a test inserting a row mid-scan and asserting no skip or duplicate |
| Sync push | **One transaction per operation.** `[good, bad, good]` → `[applied, rejected, applied]`. All eleven operation kinds tested |
| Sync pull | One unified stream, tombstones without records, `epoch:seq` watermark, stale-epoch → 409 |

### Corrections made to the spec during implementation

- **Ticket 06 amended**: comments are created with `PUT` at a caller-supplied id, not `POST` — the route table contradicted the ticket's own Writes section and ADR 0005.
- **Core's `SyncEntity`/`SyncRecord` extended** with `project` and `user`: pull is a unified stream and a client's replica needs both to render an Issue at all. Neither is pushable, which `SyncOperation` still enforces.

### Notes for whoever picks this up

- **`String + String` chains are a build hazard.** A test file assembling JSON by concatenation took the test target from 6.5 seconds to over nine minutes. Use interpolation or `JSONSerialization`.
- **Path parameter names must match across route groups at the same depth.** `/projects/:id` in one file and `/projects/:projectId/labels` in another hung the suite at runtime.
- **Types written decode-only for the client keep needing `Encodable`** — `ServerMeta`, `Paginated`, `SyncRecord`, `SyncResult`, `SyncPushResponse`, `SyncChange`, `SyncPullResponse`. Default API/sync types to `Codable`.
- Five malformed-row guards are uncovered by design: each defends against a corrupted database row whose non-lookup UUID columns are invalid, which foreign keys make unreachable in a test.

### CLI: foundations, auth and issue reads

**601 tests. Core 99.23%, Server 98.20%, CLI 86.55%** — CLI comfortably over ticket 13's 70% floor.

The decision that shaped everything else: **CLI tests run in-process against the real router**. A transport in `Tests/CLITests` dispatches a Core `HTTPRequest` straight into `IssuesRouter` through `HummingbirdTesting`, over a real in-memory database with real sessions and real password hashes. No sockets, no canned responses. This is what makes the CLI worth building before the apps — it is a contract test suite that happens to have a command line.

| Piece | Notes |
| --- | --- |
| `CommandGrammar` | `issue` as the implied noun, as a pure `[String] -> [String]` rewrite before parsing. ArgumentParser has no default subcommand |
| `ExitStatus` | Ticket 11's published codes. 3 ≠ 6 is where the server's 410-vs-404 decision finally reaches a user |
| `IssuesCLI.run` | **Returns** its exit code rather than calling `exit`, so all of dispatch is testable. Only `main.swift` exits |
| `CommandContext` | Every outside dependency as one injected value, bound as a task local because ArgumentParser owns command construction |
| `CLIConfiguration` | `config.toml` + `.issues.toml` walked up from the working directory + `ISSUES_*`, most specific winning |
| `CredentialStore` | Keychain by default, keyed by **origin**; a `0600` file store drives the tests |
| `auth login/logout/status` | The only place a password is handled. Existing sessions are not silently replaced |
| `issue list/show` | Filters map onto the API's OR-within/AND-across rule; `--limit` walks pages without ever naming a cursor |

### Corrections made to the spec during implementation

- **Ticket 06 amended**: comments are created with `PUT` at a caller-supplied id, not `POST` — the route table contradicted the ticket's own Writes section and ADR 0005.
- **Core's `SyncEntity`/`SyncRecord` extended** with `project` and `user`: pull is a unified stream and a client's replica needs both to render an Issue at all. Neither is pushable, which `SyncOperation` still enforces.
- **The User resource was never implemented.** `/users`, `/users/me` and `/users/:id` are specified in ticket 06 and `UserEndpoints` existed in Core, but no route was ever registered — the server was called complete without them. Found when `auth status` 404ed. Now built, with `/users/me` tested against being shadowed by `/users/:id` at the same path depth, and deactivation revoking the user's sessions (without that, "deactivate" would mean nothing for up to sixty days).
- **`LoginRequest`/`LoginResponse` moved into Core.** They were declared in `Server`, so the CLI could not name the type it had to decode — exactly the drift that sharing DTOs is supposed to prevent.
- **`FlatTOML` moved into Core**, shared by the server's config and the CLI's, so the two cannot come to accept different dialects of the same format.

### CLI: the write verbs

**678 tests. Core 99.23%, Server 98.17%, CLI 90.10%.**

`create`, `edit`, `comment`, `assign`, `close`, `start`, `cancel`, `reopen` and `delete`. Smoke-tested end to end against a real `issues-server` over HTTP, not only in-process.

| Decision | Why |
| --- | --- |
| **Scissors, not `#` stripping**, for editor instructions | `# Heading` is both valid Markdown and a plausible instruction, so no rule about `#` can tell them apart — and guessing wrong deletes what somebody wrote. git's `>8` marker is positional and cannot be ambiguous. A deleted marker keeps the whole buffer |
| The editor is a **closure on `CommandContext`** | No command test spawns a process. `Editor.run` itself has its own tests with a scripted `$EDITOR`, covering quoting, the temp file and a non-zero exit |
| A non-zero editor exit is an **error, not an abandoned edit** | Treating a killed editor as "saved an empty buffer" would quietly discard the text |
| **Saving unchanged is not a write** | Otherwise every opened editor bumps `updatedAt` and wins a last-write-wins race it never should have entered |
| **Flags are validated before any request** | `issues edit PROJ-1 --status finished` should say the status is unknown, not that the issue is missing. The typo is the problem either way |
| An **unknown label is refused**, naming `issues label create` | Labels are a shared, project-wide vocabulary; a tracker where every typo silently becomes a label fills with near-duplicates nobody cleans out |
| An **ambiguous assignee is refused** | Two people called "Sam" must not resolve to whichever the server returned first |
| The editor **does not open when another field was named** | `issues edit PROJ-1 --status done` must not stop for a text editor nobody asked for |
| `--unset` accepts **only nullable fields** | `Settable` makes "clear the status" unrepresentable in the API, so `--unset status` is rejected by name rather than sent and refused |

### CLI: the remaining nouns, and two gaps they exposed

**745 tests. Core 99.26%, Server 98.22%, CLI 92.33%.** `project`, `label` and `user` complete the noun surface.

Two things were missing before these could work at all:

- **There was no way to set a password.** `UserCreate` has no password field and no endpoint existed, so `issues user create` would have made an account nobody could ever log into. Added `PUT /users/:id/password`: changing your own requires the current one, an Admin resetting somebody else's does not, an agent may never do either, and any change revokes that user's sessions. Password stays out of `UserCreate` deliberately — a `PUT` create is retried after a lost response by design, and a password in a retried body is one more place it can be logged.
- **Label colour was an unvalidated `String`.** Now `#RRGGBB`, validated in Core and enforced on both create and patch, so no client has to defend against `banana` in a field it wants to draw. With no `--color`, one is picked from a fixed palette by an **FNV-1a hash of the lowercased name** — Swift's own `hashValue` is seeded per process and would give a label a different colour every restart.

| Decision | Why |
| --- | --- |
| Admin-only verbs are **listed in help for everyone** and rejected at call | Hiding them makes `--help` depend on who you are, which means help needs a network round trip and a valid token to render |
| `user create` **says the account cannot log in yet** | Otherwise it looks ready and silently is not |
| The password prompt has **no flag equivalent** | A password in argv is visible in `ps` and lands in shell history. Read twice, because a mistyped password nobody can see is an account locked out by a typo |
| Changing your own password **clears the stored credential** | The server just revoked that token; leaving it would make the next command fail with a confusing 401 |
| Unarchiving and reactivating **do not confirm** | They are not destructive, and a prompt would make undoing a mistake harder than making one |

### Personal access tokens: `auth token`

**799 tests. Core 99.29%, Server 98.34%, CLI 92.74%.** This completes ticket 11's command surface, and it is what makes an agent token mintable — which MCP depends on.

Needed a server slice first: `GET/POST /api/v1/auth/tokens`, `DELETE /api/v1/auth/tokens/:id`, and `GET /api/v1/users/:id/tokens`, plus **migration v5** adding a public `id` to `session`.

| Decision | Why |
| --- | --- |
| A token's public id is a **new UUIDv7 column**, not its hash | A public identifier should never be derived from a secret. The migration **backfills existing rows**, or the one token an admin most wants to revoke is the one they cannot name |
| Minting **always requires the password**, even holding a valid token | Otherwise a leaked token mints children and revoking the original leaves them working — the compromise outlives the revocation. Cost: `auth token create` cannot run headlessly, which is right; CI should be handed a token, not mint one |
| An **agent may never mint a token** | An agent issuing a human-kind token would escape ADR 0007 entirely by granting itself its owner's full authority |
| `POST`, not `PUT` at a caller-supplied id | The only create here that is not a `PUT`. A token is not a synced entity, cannot be made offline, and its response carries a secret that exists once; a client-chosen id would buy nothing |
| An **unknown kind is refused at the door** | Stored verbatim it would authenticate and grant no capabilities at all — confusing rather than safe |
| Revoked tokens **stay in the listing**, marked | A listing is what an Admin reads to work out what happened; dropping the revoked rows hides the evidence |
| Revoking twice reports **410, not success** | A script needs to tell "I revoked it" from "somebody already had" |
| `TokenKind` **moved to Core** as a lenient `WireEnum` | Clients read it (ticket 07 keeps the kind on the token so an Admin can spot an agent). An unrecognised kind grants **no** capabilities — defaulting to human would widen an unknown token to the maximum |
| Login sessions are **labelled** | An unlabelled row in a revocation list tells an Admin nothing |

**Prompts moved to stderr.** Found by `TOKEN=$(issues auth token create -q)` capturing `"Password: "` along with the token. Every prompt, hidden-password newline and destructive confirmation now goes to stderr, so stdout is exactly what the caller asked for. There is a dedicated suite holding that line.

### Shell completions

**811 tests.** `issues completion zsh|bash|fish`, which finishes ticket 11's table.

ArgumentParser generates the script from the command surface itself, so completions cannot drift from the commands the way a hand-written script would. The command wraps the built-in `--generate-completion-script`, because nobody guesses a flag.

What is worth testing here is not the generator but that our surface produces a script each shell will actually load — **a broken completion script is worse than none, because it errors on every shell start-up**. So each script is run through its own shell's parser (`zsh -n`, `bash -n`, `fish --no-execute`), and both zsh and bash were additionally verified to *register* the completion when sourced.

- **`--status`, `--priority`, `--kind`, `--role`, `--sort`, `--assignee` and config keys carry completion lists.** That is the actual value: `inProgress` and `agentReadonly` are the spellings nobody remembers.
- **No dynamic completion** of project keys, issue keys or label names. Those would need a network call on every Tab, in a tool whose appeal is being fast, and would fail confusingly offline.
- **fish is skipped, not failed, when absent** — a red suite for a missing shell teaches people to ignore red suites. It is therefore **unverified on this machine and in CI**, since neither has fish installed.

### Client sync engine: the causal rules and the store

**882 tests. Core 99.07%, Server 98.34%, CLI 92.84%, ClientStore 94.35%** (floor 85).

Started on the client engine rather than a throwaway harness: ticket 05 and ADR 0008 specify the design closely enough that a harness would have been the same work, then discarded. It is a new Apple-only target (`ClientStore`) with no UI, driven entirely by tests.

**Core's pure rules first**, as ticket 05's input 4 insists — replay ordering is a domain contract, so it must be provable without a database:

- `SyncDependencies` — `target`, `prerequisites`, a **stable topological `ordered`**, and `blocked`. Projects and Users are deliberately *not* prerequisites: no operation can create one, so listing them would imply the queue might reorder to satisfy them, when an issue naming an unknown project simply has to fail at the server.
- `SyncCoalescing` — patch merging, folding into an unsent create, and the two hard exclusions. Merging one entity's patches *through* writes to other entities is safe and deliberate: dependencies are on ids existing, never on another entity's field values.

**A real ordering bug, caught while building the sort.** A patch with no prerequisites of its own looked "ready" and overtook its own create, which was still waiting on a label — so the patch would have reached the server before the record existed. Fixed by skipping any operation with an earlier unemitted sibling; there is a test named for it.

**The store**: one SQLite file holding both replica and queue, because "apply locally *and* enqueue, or neither" has to be one transaction. There is a test that a failed enqueue rolls back the local write — without it the device is silently ahead of the server with nothing able to detect it.

| Decision | Why |
| --- | --- |
| **Foreign keys off** on the client | Pull order is change order, so a comment can arrive pages before its issue. Enforcing them breaks first sync; orphans are stored and not displayed |
| `pending_operation`'s primary key is a **sequence**, not the opId | Two operations made in the same millisecond must still have a defined order, and `created_at` cannot give one. The UUIDv7 trap, avoided by design this time |
| **Partial index** on `state = 'pending'` | ADR 0004's no-head-of-line-blocking guarantee as an index rather than a code convention |
| Label membership converges on **`(issue_id, label_id)`** | Mirrors the server. Each client invents its own row id; the natural key is what makes them converge |
| An undecodable queue row is **skipped, not fatal** | One bad row must not make the whole queue unreadable, which is exactly when it matters most |

### The sync protocol, exercised by a client at last

**921 tests. ClientStore 98.45%.** `SyncEngine` pushes and pulls against the **real router** — real routing, real persistence, the real push and pull services, no canned responses. This is the first time the protocol has been driven by a client rather than by the server's own tests, and it found two things.

**A real bug: a locally created row kept its placeholders forever.** A client cannot know an issue's `reporterId` or `via` — both come from the token server-side — so a local create inserts placeholders. The pull's `ON CONFLICT DO UPDATE` listed only the mutable fields, treating the rest as immutable, so the authoritative record never replaced them. Now `project_id`, `reporter_id`, `via` and `created_at` are all overwritten on the first real record, for issues, comments and labels alike.

**A test whose premise was wrong.** I expected a comment queued behind a bad create to be reported *blocked*. It is not: on the first push nothing is known bad yet, so both go out and the server rejects each on its own merits — which is better, because each gets its own error. Blocking matters on the *retry*. Both behaviours now have a test, and the second is named to say it is the behaviour rather than a bug.

| Decision | Why |
| --- | --- |
| Push **does not adopt** the push response's watermark | It is the server's position *after* the batch, so taking it would skip everything before — on a first sync, the entire history. There is a test for exactly that |
| `sync()` is **push then pull** | The pull afterwards carries this device's own writes back with the server's timestamps, so the replica ends up holding exactly what the server holds |
| **One transaction per pulled page** | A crash mid-page must not leave the watermark ahead of the records it claims to cover, which would skip those changes permanently |
| A stale epoch **resyncs but keeps the queue** | Base records are rebuildable; unsent user work is not. Losing it to a server-side restore is the silent data loss ADR 0004 forbids. Tested, including that the kept work still reaches the server afterwards |
| A superseded write **leaves the queue** rather than being quarantined | Quarantine means repair and retry, and there is nothing left to retry against. The payload is handed back intact with what beat it |
| A tombstone for an **unseen** record still creates a row | Pull order is change order, so a tombstone can arrive first. Forgetting it would resurrect the record on a later pull |

Proven end to end: a write on one device reaching another, and **concurrent edits to different fields both surviving** — the per-field last-write-wins claim the whole architecture rests on.

### The read-time overlay, and a correction to the store

**944 tests. ClientStore 99.53%.** This completes ticket 05.

Building the overlay exposed a tension in what the store did the day before: `enqueue` wrote changes straight into the base tables, so the base was not server-authoritative and ticket 05's "base plus pending applied on read" would double-count. **Resolved by moving application to acknowledgement time**:

- A **create** still writes a provisional row, because there is no server record to overlay onto and without a row a list would have to merge unsent creates in Swift rather than SQL.
- A **patch or delete** touches nothing until the server accepts it. That is what makes discarding a quarantined operation revert cleanly — previously the rejected value was baked into the row and survived until the next pull — and what stops a rejected delete leaving the replica claiming a deletion that never happened.
- `acknowledge` now **applies and dequeues in one transaction**. An operation removed but not applied would leave the replica stale with nothing left to replay it.
- `discard` is separate, for superseded writes and for a quarantined one the user throws away: in both cases the change must *not* reach the base.

**A real bug caught by its test.** A locally created issue inserted `reporter_id = ''`, which is not a parseable UUID, so the row was skipped on read — an issue made offline would have been **invisible until it synced**. Now a named zero-UUID placeholder, replaced by the first authoritative record.

| Decision | Why |
| --- | --- |
| A **quarantined** operation still overlays, flagged | The user typed that text and it is theirs to repair. Hiding it would make a rejection look like their work had been thrown away |
| Dirty state is **per field** | Ticket 05's stated reason for keeping the queue as the record of what is locally changed: conflict presentation needs to mark individual values |
| The base row for a **local delete** is untouched | A rejected delete then needs nothing undone |
| Pending operations for a page are fetched in **one query** | A list of fifty issues would otherwise be fifty-one |

Proven through the real sync loop: an edit stays visible from typing through to acknowledgement without flickering; **a pull arriving mid-edit does not wipe unsent text** while still delivering somebody else's change to another field; an offline create keeps its place in the list and gains its server-assigned key; and a rejected edit stays on screen, flagged, with its text intact.

`PendingOperation` lost its `Identifiable` and `Hashable` conformances — nothing used them, and a hand-written `hash` no test exercises is a liability.

### Superseded writes, and the tombstone-on-pull path

**955 tests. ClientStore 99.60%.** The client engine is now complete against ticket 05.

Ticket 05 asks for this in two places, and only one was built:

- **Push** returns `superseded` when the entity is tombstoned. That was handled, but only *returned* — a summary from a sync nothing was watching is the same as losing the user's text. It is now persisted in a `superseded_write` table (migration v2).
- **Pull** was the missing half. A tombstone arriving for an entity with pending edits now drops that work immediately and records it, rather than leaving it to fail at the next push. The user learns as soon as the client knows.

Dropped **transitively**, which falls straight out of the derived dependency rule: a pending comment on a deleted issue goes too, and an edit to that comment after it. Three reasons are distinguished — `rejectedByServer`, `deletedElsewhere`, `dependencyRemoved` — because "the server refused it" and "somebody deleted the issue while you were typing" are different things to tell a person.

| Decision | Why |
| --- | --- |
| Dropped, never **quarantined** | Quarantine means repair and retry, and there is nothing left to retry against. A quarantined operation here would fail forever |
| Kept **until dismissed**, not expired | It is the user's text; deciding when they have finished with it is not ours to make on a timer |
| `current` is stored when the server supplies it | So the UI can show what won beside what was lost |

Tested that unrelated pending work is untouched and still goes out afterwards — the same no-head-of-line-blocking property, in a different guise.

### `expand`, and the N+1 it removes

**981 tests.** Ticket 06 specified it, Core had the `Expansion` type, and no route had ever read the parameter.

**The response shape is strictly additive**: `assigneeId` and `assignee` both appear, side by side. That is what let this be added to a live API with no version change — the CLI's existing `Paginated<Issue>` decode keeps working whether or not expansion is asked for, and there is a test asserting an expanded payload still decodes as a plain `Issue`.

| Decision | Why |
| --- | --- |
| Additive keys rather than a wrapper or a sidecar | A wrapper means a client decodes one of two types depending on the request it made; a sidecar means every one of five surfaces joins client-side, which is the opposite of the ergonomics `expand` exists for |
| **Batched**, four queries whatever the page size | Expansion exists to remove an N+1; resolving it per row would reintroduce the exact problem. Tested by measuring the query count for 1 issue and for 41 and asserting they are **equal** — the absolute number is uninteresting, the growth is the property |
| An unknown expansion is **refused** | Silently expanding nothing looks identical to a server that does not support the relationship, and the caller cannot tell |
| `labels: []` ≠ absent | Requested-and-none is a different answer from not-requested, and a client rendering a label row needs both |
| The CLI expands **only for the human table** | `--json` must stay the plain payload a script expects, and `--quiet` needs nothing but keys |

The CLI's `UserDirectory` — a second request per list, added when the server could not expand — is now deleted.

### The apps: shared behaviour layer

**1,014 tests. AppCore 97.04%** (floor 80, per ticket 13's view-model rule).

Ticket 10's variant C keeps the behaviour written **once** and placed per platform, so the shared layer lives in a package target rather than in either app shell. That keeps it driveable from `swift test` — and `make build-ios` compiles it for iOS on every CI run, because nothing else in the suite would notice it breaking there.

**All five required sync surfaces now have state**, which is what makes them surfaces rather than decoration:

| Surface | Where it comes from |
| --- | --- |
| Quarantine (needs attention) | `quarantinedWork()` — rejected writes with their problems |
| Superseded-by-deletion | `supersededWrites()` — the user's text, kept |
| Needs re-authentication | A state on the model, deliberately **not** derived from a query: a rejected token is not a rejected write, and the remedy is logging in rather than repairing |
| Full-resync progress | `.rebuilding`, presented as normal recovery rather than as an error |
| **Advisory pre-push warning** | New. `staleEdits()` compares an unsent edit's own timestamp with the base record's `updatedAt` |

The advisory check had no implementation anywhere. It is the **only** place a user can learn their offline edit is about to overwrite newer work, because ADR 0005 rejected optimistic concurrency deliberately — there is no server-side veto to fall back on.

- It warns with a **one-second threshold**, not on strict inequality. Timestamps lose sub-millisecond precision differently through SQLite and through JSON, so two records written from the same instant come back microseconds apart; warning on that noise teaches people to ignore the warning. Found by a test that compared two round-tripped dates for equality — the same precision trap as before.
- **Advisory, never a veto**: a stale edit still pushes, and there is a test saying so. Last-write-wins is the intended behaviour.
- A **create is never stale** (nothing to overwrite) and a **delete is never flagged** (terminal by design, ADR 0003).

**`attentionCount` deliberately excludes queued work and advisory warnings.** A badge that is always lit is a badge nobody reads: ordinary pending work is going out on its own, and a stale-edit warning would keep the badge on for as long as an old edit sits in the queue.

Also here: the `unknown`-enum read-only rule (a picker would let a user clobber a value this build cannot represent), the no-key-until-first-sync state, and a deleted comment keeping its place in a thread.

### The apps: shared components, and a way to look at them

**1,052 tests. AppCore 97.36%.** Atoms, `IssueRowContent` and `SyncStatusView` — all five sync surfaces in one implementation.

**`AppViews` is a separate target from `AppCore`, and that split is the point.** Ticket 13 gates view models and exempts view bodies; with the views in `AppCore` the figure fell to **57%**, which would have meant either gating untestable bodies or abandoning the gate on the models. Split, anything that can be wrong lives in `AppCore` where it is tested, and the bodies are left with nothing to decide — colours come from a named `Emphasis`, copy and symbols from `SyncSurface`, the key placeholder from `IssueKeyPresentation`.

**`issues-preview`** renders every component with every sync state at once — the successor to ticket 10's HTML prototype, and just as throwaway. Screenshot: [../preview/gallery.png](../preview/gallery.png).

It immediately earned itself: **rows without a dirty dot did not line up with rows that had one**, because a hidden indicator collapses the `HStack` and shifts every title left. A list whose titles jitter as items sync is exactly the class of fault no unit test would have caught. Both state indicators now reserve their space.

| Decision | Why |
| --- | --- |
| A due date renders anchored at **midday GMT, formatted in GMT** | A calendar day through an ordinary formatter shifts: 1 January in London reads as 31 December further west, so a task due on the first looks overdue. Midday rather than midnight so no daylight-saving transition can move the day either |
| An unrecognised status or priority is shown **verbatim** | It came from the server and the user may well know what it means. It gets no colour implying a category it does not have |
| A **human** record carries no `via` badge | Marking the common case would bury the uncommon one, and the point of `via` is spotting what the bot filed |
| Buttons are named for the action — "Recover text", not "View" | The user should know what happens before pressing |
| An unparseable label colour falls back to grey | The server validates the format, but an older record must not crash a list over a swatch |

Copy is asserted, not just written: the lost-to-deletion surface must say "deleted" and must **not** say "someone else edited this field" — which cannot happen under receipt-time last-write-wins — and **no surface may imply freshness**, since iOS background refresh has no timing guarantee and "updated 2 minutes ago" becomes a lie the moment a refresh is missed.

### Open gaps

- **Four unreachable defensive lines in Core are uncovered**, which is why the baseline moved from 99.29% to 99.07%: three `default: nil` folds that a per-entity slot can never reach, and the cycle fallback in the topological sort, which this domain cannot produce. The fallback emits the queue head rather than stopping, because silently dropping operations is the one outcome ADR 0004 forbids.
- **The `via` badge may be too subtle.** Ticket 12 wants attribution legible "at a glance"; it is currently a small secondary-tinted glyph. Visible in the gallery screenshot — worth a look before the app shells fix the layout around it.
- **The server's SQLite files are `0644` inside a `0700` directory.** Protection is directory-level by design, but a file moved or copied out of it carries no protection of its own. Worth a `chmod` after open.
- **`.issues.toml` may not set `url`** — a repository-controlled file that could retarget the CLI at another host would make `git clone` enough to redirect traffic. Refused explicitly, and tested.

### Notes for whoever picks this up

- **`String + String` chains are a build hazard.** A test file assembling JSON by concatenation took the test target from 6.5 seconds to over nine minutes. Use interpolation or `JSONSerialization`. The same blowup recurs inside `#expect` — hoist anything with `map`/`reversed` into a typed local first.
- **Path parameter names must match across route groups at the same depth.** `/projects/:id` in one file and `/projects/:projectId/labels` in another hung the suite at runtime.
- **Types written decode-only for the client keep needing `Encodable`** — `ServerMeta`, `Paginated`, `SyncRecord`, `SyncResult`, `SyncPushResponse`, `SyncChange`, `SyncPullResponse`. Default API/sync types to `Codable`.
- **`ExitCode` collides with ArgumentParser's own type**; the CLI's is `ExitStatus`. `CommandError` is not public, so a parse failure is identified by ArgumentParser's own `exitCode(for:)` classification.
- **A leading `-` cannot start an option's value**: `--sort -updated` parses as a flag. `--reverse` exists because of it; `--sort=-updated` also works.
- **`$HOME` is ignored by both `FileManager.homeDirectoryForCurrentUser` and `URL.applicationSupportDirectory`** — they read the password database. Smoke tests run with `HOME=/tmp/...` wrote into the real home twice: once a config file, once a whole SQLite database. Both the CLI and `ServerEntryPoint` now resolve `$HOME` first, which is also what makes a throwaway instance possible at all.
- **UUIDv7 does not order within a millisecond** — its tail is random. `ORDER BY id DESC` on rows created back-to-back returns them arbitrarily, which showed up as a test passing once and failing the next run. Order by a timestamp with the id as a tie-break. This is the *second* time this trap has cost time; the first was a Core ordering test.
- **`guard case .unknown = value else { throw }` is inverted** — it throws when the value *is* known. `if case .unknown = value { throw }` is what you want, and a test caught it in `user create --role`.
- **A pty is needed to smoke-test anything interactive**, and `script` cannot allocate one here while `python3 -c` with the program on stdin deadlocks. Test the seam directly instead.
- **The coverage gate keeps finding missing *positive* paths**, never missing negative ones. This session: no test that an Admin could promote anyone, none for `--project`, `--priority` or `--server`. Write the allow case beside the deny case, every time.

### Next

1. **`IssueDetailContent`** — field stack, read-only states for unrecognised enum values, and the comment thread. The last shared component.
2. **The app shells**: an Xcode project with the macOS composition (`NavigationSplitView`, sortable `Table`, keyboard-first, plus the Mac-only token and session administration) and the iPhone/iPad ones.
3. **MCP** last.
