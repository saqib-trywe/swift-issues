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
