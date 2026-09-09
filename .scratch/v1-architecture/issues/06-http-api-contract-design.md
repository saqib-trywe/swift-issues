# HTTP API contract design

Type: grilling
Status: resolved

Blocked by: 01

## Question

Design the HTTP API contract for v1: resource shape and routes for Project/Issue/Comment/User, request/response payload formats, pagination, filtering/search parameters, versioning strategy, and error response format. This is the contract every client (native apps, CLI, MCP) codes against, so nail down conventions (naming, casing, timestamps) as well as the resource list. Build on the resolved [Domain model v1](../issues/01-domain-model-v1.md).

## Inherited constraints (from resolved ticket 01)

- `key` on Issue is **nullable** until first sync — the wire format must express an Issue that has no Issue Key yet.
- Ids are client-generatable UUIDv7, so **create is effectively an upsert with a caller-supplied id**, not a server-allocating POST.
- Status, Priority and Role must be **leniently decodable** by clients (unknown values preserved verbatim, not coerced), since a self-hosted server can be upgraded ahead of its clients.
- Leave room for **attachments** in the resource shape without implementing them — they are out of v1 scope but are the likeliest early addition.
- Timestamps are UTC instants, except `dueDate`, which is a timezone-free calendar date and must not be serialised as an instant.

## Resolution

Locked. The load-bearing shape decisions are in [ADR 0005](../../../docs/adr/0005-two-write-paths-one-concurrency-model.md). Auth is ticket 07; sync *semantics* are ticket 08 — this ticket fixes only the envelopes they must fit.

### Two contracts

- **REST resource API** (`/api/v1/...`) — used by CLI, MCP, scripts, humans.
- **Sync pair** (`POST /api/v1/sync/push`, `GET /api/v1/sync/pull`) — used only by the offline-first native apps.

Both are generated from the same DTOs and validation in Core. That shared origin is the anti-drift mechanism; without it the two paths diverge within a release.

### Conventions

- JSON, **camelCase** keys. Every consumer is Swift; snake_case buys only `CodingKeys` boilerplate in five places.
- Timestamps **RFC 3339, explicit `Z`, millisecond precision**. `dueDate` is `"2026-09-07"` — a plain date string, structurally distinct from an instant.
- UUIDs lowercase canonical hyphenated. Enums are **lowerCamelCase strings** (`inProgress`), never integers — integers make logs unreadable and lenient decoding pointless.
- Single resources returned bare; collections wrapped in an envelope carrying pagination metadata.
- **Versioning**: path prefix `/api/v1/`, one global version. Lenient enum decoding absorbs additive change, so v2 is reserved for genuinely breaking shape changes.

### Routes

| Route | Notes |
| --- | --- |
| `GET/PUT/PATCH/DELETE /api/v1/projects[/{id}]` | |
| `GET/PUT/PATCH/DELETE /api/v1/issues[/{id}]` | **Top-level, not nested under project** — the commonest query is cross-project ("assigned to me"); project is a filter |
| `GET /api/v1/issues/PROJ-142` | Resolves by Issue Key alongside UUID, disambiguated by format. Humans and agents hold keys, not UUIDs |
| `PATCH /api/v1/issues/{id}/labels` | Body `{add: [...], remove: [...]}` |
| `GET/POST /api/v1/issues/{id}/comments`, `/api/v1/comments/{id}` | |
| `GET/PUT/PATCH/DELETE /api/v1/projects/{id}/labels[/{labelId}]` | Nested: Labels are project-scoped by definition |
| `GET /api/v1/users[/{id}]`, `/api/v1/users/me` | |
| `GET /api/v1/meta` | Authenticated. Server version, supported API versions, instance name — the skew-detection hook |
| `GET /health` | **Unversioned, unauthenticated**, liveness only, no data. Feeds ticket 09 probes |

The **IssueLabel link record is deliberately not a REST resource.** It is a sync convergence mechanism (ADR 0003); exposing link ids would leak internal machinery into the surface CLI and MCP touch. The add/remove delta shape preserves concurrent-add semantics without it.

### Writes

- **`PUT /api/v1/issues/{id}` is create-only and idempotent** — no `POST /issues`. A repeated identical PUT returns the existing resource; a PUT to an existing id with different content returns **409**. An offline client retrying a create it never saw a response to must not produce two issues, and full-replace PUT would let a stale retry clobber newer field values that per-field LWW should have preserved.
- **All mutation is `PATCH` with JSON Merge Patch semantics (RFC 7386)**: key absent = untouched, `null` = cleared, value = set. Core needs a three-state `Patchable<T>` (`.unchanged` / `.set(T)` / `.cleared`) that distinguishes absent from null, because Swift's `Decodable` collapses both to `nil` by default. Get this wrong and either nothing can ever be unassigned, or every PATCH wipes every field it didn't mention. It is also exactly what per-field LWW wants: **only keys present in the PATCH get their field timestamps bumped**.
- **Unknown enum values are rejected on write with 400.** The server owns the value set. Corollary for clients: a field holding an `unknown` value is **read-only in that client** — disable the picker rather than offer a rewrite that would clobber a value it cannot represent.

### Reads

- **Cursor pagination**: opaque `cursor` + `limit` (default 50, max 200), response carries `nextCursor`. Offset paging silently skips and duplicates rows while issues are being created and deleted mid-scan.
- **Filtering** is flat query params over a fixed vocabulary, not a DSL: `?projectKey=&status=&assignee=&label=&priority=&updatedSince=&q=&sort=-updatedAt`. Comma values are **OR within a parameter, AND across parameters**. `assignee=me` and `assignee=none` are special tokens. `q` is substring over title + description in v1. Accepted cost: no OR across fields, no negation.
- **`?expand=labels,assignee`** — opt-in, whitelisted (labels, assignee, reporter, project), **one level deep, no recursion**. Without it a 50-row list view is an N+1; as a default it bloats every scripted call.
- **Comments are never embedded.** An issue with 200 comments must not be one response.
- **Deleted resources return 410 Gone, not 404** — "existed and is gone" is a genuinely different message from "no such id". Lists exclude deleted; there is **no `includeDeleted` param**, because exposing tombstones over REST invites a second ad-hoc sync built on the resource API.

### Errors

**RFC 9457 Problem Details** (`application/problem+json`), stable machine-readable `type` slug, plus an `errors: [{field, code, message}]` extension for validation failures — a stable `code` lets five surfaces react without string-matching English.

### Sync envelopes

**Push** carries operations mirroring the REST verbs (`put` / `patch` / `delete`) over the same payload DTOs. Each operation has an `opId` **distinct from its `entityId`**, so a retried partially-applied batch dedupes.

Push **always returns 200 with a per-operation result array** — never a top-level 4xx for individual failures, which is what makes quarantine-without-head-of-line-blocking (ADR 0004) implementable. Top-level 4xx is reserved for a malformed batch or auth failure. Three outcomes:

- `applied`
- `rejected` — quarantine; carries the RFC 9457 problem
- `superseded` — the write lost last-write-wins; carries the current server record

`superseded` is what makes ADR 0001's "the losing edit is surfaced, not silently dropped" real. With only applied/rejected there is nowhere to express "your edit was valid but someone beat you", and it would be reported as success while the user's text disappeared.

Caps: 500 operations or 5MB per batch. The response carries the current watermark so the client can pull from exactly there.

**Pull** is a **single unified change stream across all entity types**, not per-type endpoints — causal order matters coming down too (a Comment must not arrive before its Issue), and one watermark is one resumable position rather than six that skew apart. The watermark is an **opaque server sequence token, not a timestamp**: timestamps tie, and a tie at a page boundary duplicates or drops records. **Tombstones are first-class entries** (`deleted: true`, minimal record) — the only way deletes propagate. Deltas carry full records, not field diffs. First sync is `since` omitted; no separate bootstrap route.

Pull **echoes the client's own writes back rather than filtering by device** — they return with authoritative server timestamps and any normalisation, so a client that mis-tracked its own write self-heals. Filtering saves a little bandwidth and creates a bug class where a partially-applied push leaves a client permanently wrong with no correction coming.

### Concurrency

**No `ETag` / `If-Match` in v1.** It would create a second concurrency model contradicting the first — reject-on-conflict for REST, last-write-wins for sync, over the same rows — so behaviour would depend on which client you happened to use. Merge Patch already limits blast radius to the fields a request names. Responses carry `updatedAt` so a client can detect it lost. Accepted cost: two CLI users editing one field seconds apart, last wins, no warning.

### Limits

No rate limiting in v1 — single-team self-hosted, everyone authenticated and identifiable, so abuse is a social problem. Hard caps only: 5MB body, 500 ops per batch, 200 items per page. **Exception worth watching: MCP agents**, which loop in ways humans don't; flagged on ticket 12.

### No special endpoints for CLI or MCP

Both use the same REST surface. The concessions they need — Issue Key lookup and `assignee=me` — are already in it. Separate routes would fork the contract.

## Amendment (2026-09-08, from ticket 09)

**The opaque watermark encodes an instance epoch: `epoch:seq`.** It was already specified as opaque, so this is a refinement of its contents rather than a change to the contract's shape — but clients must treat a **stale-epoch response as an instruction to full-resync**, so the sync endpoints need a way to say that (a distinct problem `type` on pull).

Reason: `issues-server restore` rewinds the monotonic sequence, and without an epoch a client holding watermark 900 against a server restored to 400 would see `seq > 900` return empty **forever** — believing it was current while silently diverging, with no error raised anywhere.

## Amendment (2026-09-09, from implementation)

**Comments are created with `PUT` at a caller-supplied id, not `POST`.** The route table above lists `GET/POST /api/v1/issues/{id}/comments`, which contradicts this ticket's own Writes section and [ADR 0005](../../../docs/adr/0005-two-write-paths-one-concurrency-model.md).

The reasoning that ruled out `POST /issues` applies identically to comments: an offline client retrying a create it never saw a response to must not post the same comment twice. `POST` cannot be idempotent without a separate dedupe key, which is exactly what a caller-supplied UUIDv7 already is.

Concretely: the **collection** is nested (`GET /api/v1/issues/{id}/comments`), the **resource** is top-level (`GET/PUT/PATCH/DELETE /api/v1/comments/{id}`), and `issueId` travels in the create body. Same split as Issues, which list under a project filter but are addressed at `/issues/{id}`.

The same applies to every other create: Project, Label and User are all `PUT` at a caller-supplied id.
