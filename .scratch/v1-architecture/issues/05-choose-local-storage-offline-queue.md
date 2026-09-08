# Choose client-side local storage & offline queue design

Type: grilling
Status: resolved

Blocked by: 01, 03

## Question

Given the findings from [Client-side local storage research](../issues/03-local-storage-research.md) and the resolved [Domain model v1](../issues/01-domain-model-v1.md), choose the client-side local storage technology and design the offline pending-operation queue: what gets queued (create/update/delete per entity?), how it's persisted, how it's replayed on reconnect, and how a replay failure/conflict is surfaced to the sync protocol layer. Record the choice as an ADR.

## Inherited constraints (from resolved ticket 01)

Per [ADR 0004](../../../docs/adr/0004-offline-write-failure-contract.md), the queue design is not free on these points:

- The queue is a **topologically ordered log, not merely chronological** — parents replay before children, because the server rejects any reference to an id it has not seen.
- A server-rejected operation is **quarantined** with its error and surfaced for repair or deliberate discard, never silently dropped.
- A quarantined operation **must not block the rest of the queue**. Only operations causally dependent on it are held back. Head-of-line blocking is the specific failure mode to design against.
- Storage must hold per-field timestamps for Issue's six mutable scalars, and tombstones (`deletedAt`) retained indefinitely for Issue, Label, IssueLabel and Comment.

## Resolution

**GRDB**, one database file, replay ordering in Swift. Recorded in [ADR 0008](../../../docs/adr/0008-grdb-client-storage-and-offline-queue.md). Findings that drove it: [research/03-local-storage-landscape.md](../research/03-local-storage-landscape.md).

### The four inputs settled first

The technology was deliberately chosen **last**, because the research showed four other questions determine it.

1. **Minimum deployment target: 26.** The project's stated policy is latest-*released*-only, and 27 is not released. This is the deciding input: SwiftData's non-SwiftUI change observation (`ResultsObserver`, `HistoryObserver`) is 27-only, so on 26 its background-write→UI-refresh path is `willSave`/`didSave` plus history polling for this entire release.
2. **The strict-concurrency gate means "the compiler proves our data-race safety"**, not "it builds cleanly in Swift 6 language mode". Under the weak reading `@unchecked Sendable` satisfies the gate and the project's structured-concurrency policy is decorative. Under the strict reading the gate does real work — and it eliminates hand-rolled SQLite, which passes only by assertion (`OpaquePointer` is non-`Sendable` per SE-0331).
3. **Linux reuse of the client store is not a requirement.** CLI and MCP are locked as online-only and stateless (tickets 11, 12); the server has its own database. Storage is an Apple-only module that Linux targets do not import, so Core's models, API client and validation still build and test on Linux. This forecloses a future headless Linux sync client, which is not planned.
4. **Replay ordering is an application property, not an engine property.** ADR 0004's causal ordering is a domain contract: it should be unit-testable without a database, reviewable by the whole team, and unchanged if storage ever changes. A recursive CTE puts a load-bearing invariant in a language the Swift test suite cannot easily exercise.

### Technology

**GRDB**, on the two axes the research ranked highest:

- **Atomicity.** "Apply the local mutation *and* enqueue the operation, or neither" is what ADR 0004's no-silent-drops guarantee rests on, and its failure mode is silent divergence found days later. GRDB's `write { }` closure **is** the transaction, with documented rollback-on-throw. SwiftData's `transaction(block:)` with `autosaveEnabled = false` is a convention reapplied at every call site.
- **Partial indexes.** Quarantine-without-head-of-line-blocking is an ADR 0004 hard requirement, and a partial index on pending state is exactly how it is expressed. SwiftData offers `#Index` only.

Hand-rolled SQLite is out under input 2, and would mean maintaining several thousand lines GRDB has already debugged.

**Cost, stated plainly**: we give up `@Query` — genuinely the fastest path to a working SwiftUI list — for roughly a day writing an `@Observable` wrapper, and we take single-maintainer bus-factor risk, mitigated by MIT licensing, a forkable codebase, and a thin layer over an engine with a 20-year compatibility record.

### Storage shape

- **One SQLite database, one file**, holding both the replica and the queue. This is what makes the atomicity argument real: the local mutation and its pending operation are one `write { }` transaction. Split across two stores no transaction spans them, and a crash between the writes diverges the device with nothing to detect it.
- **`DatabasePool` in WAL mode**, not `DatabaseQueue` — the UI reads constantly while the sync engine writes in the background, and a serial queue would make every background write block the interface. Held behind a storage actor.
- Observation via **`ValueObservation.values(in:)`** as an `AsyncSequence`, wrapped in a small `@Observable` type in the app layer. **No dependency on GRDBQuery** — pre-1.0 and unpushed since March 2025; taking a stale pre-1.0 dependency to save a day already budgeted is a bad trade.

### Queue

`pending_operation` table:

| Column | Notes |
| --- | --- |
| `opId` | UUIDv7, PK — the same id sent on the wire (ticket 06), so server-side retry dedupe works |
| `entityType`, `entityId` | |
| `kind` | `put` / `patch` / `delete` |
| `payload` | JSON, **Merge-Patch shaped**, so replay is a direct translation rather than a re-derivation |
| `createdAt` | |
| `state` | `pending` / `inFlight` / `quarantined` |
| `problem` | JSON, nullable — the RFC 9457 body |
| `attemptCount` | |

- **Partial index on `state = 'pending'`**, so the next-batch query never scans quarantined rows. That is the head-of-line-blocking guarantee expressed as an index rather than a code convention.
- Quarantined operations **keep their full payload** so the user can repair and retry.
- **Causal dependencies are derived, not stored.** The domain has few relationship types (comment→issue, issueLabel→issue and label, issue→project), so the rule is a small pure function in Core — which is input 4 in practice. A stored edge list is state that can drift from the records it describes.

### What gets queued

**Field-level patch operations mirroring the API verbs**, recording only fields the user actually changed. A whole-record snapshot carries stale values for untouched fields, and under per-field last-write-wins those stale values would win against someone else's newer edit — silently reverting their work.

**Coalescing**: patches to the same entity merge while still pending and unsent, later values winning per field, and fold into a preceding unsent create. Replaying forty title patches yields the same end state as one, at forty times the cost and forty chances to fail. Two hard exclusions — **never coalesce across a delete** (terminal), and **never reorder relative to another entity's causal dependencies**; merging happens within one entity's own run.

### Local state derivation

**Only the server-authoritative base record is stored; the displayed value is that base with pending operations applied on read.** The queue already is the record of what is locally dirty, so a second full copy would be redundant state that can disagree with the log — and this makes "which fields are dirty" trivially answerable, which the UI needs for conflict presentation. If the read-time overlay ever costs too much, a materialised column is a later optimisation, not a design change.

### Tombstone arriving for an entity with pending edits

**Drop the pending operations and surface them as superseded-by-deletion — do not quarantine.** Quarantine means *repair and retry*, and there is nothing left to retry against; leaving them pending produces an operation that fails forever. The user gets their text handed back, the same treatment as a `superseded` outcome (ADR 0005). This applies transitively — a pending comment-create on a deleted issue is discarded with the same message, which falls out of the derived dependency rule. The replica applies the tombstone.
