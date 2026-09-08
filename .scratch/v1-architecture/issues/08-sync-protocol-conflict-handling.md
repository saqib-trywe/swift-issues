# Sync protocol & conflict handling design

Type: grilling
Status: resolved

Blocked by: 01, 05

## Question

Design the sync protocol between client and server: how a client's queued offline operations are sent and applied, how the client pulls down server-side changes it's missing, how last-write-wins conflicts are detected and surfaced to the user per the agreed model ([ADR 0001](../../../docs/adr/0001-self-hosted-single-tenant-offline-sync.md)), and what triggers a sync (foreground, manual refresh, background fetch) per platform. Builds on the resolved [Domain model v1](../issues/01-domain-model-v1.md) and [Choose client-side local storage & offline queue design](../issues/05-choose-local-storage-offline-queue.md).

## Inherited constraints (from resolved ticket 01)

Per [ADR 0003](../../../docs/adr/0003-identity-and-conflict-resolution.md) and [ADR 0004](../../../docs/adr/0004-offline-write-failure-contract.md):

- Conflicts are arbitrated by the **server's receipt timestamp**, not client wall clocks. "Last write wins" therefore means last to *reach* the server — an older offline edit can lose to a newer one that synced first, and the protocol must surface that to the loser rather than hide it.
- Per-field resolution applies to Issue's six mutable scalars; Comment resolves per record.
- **Deletion is terminal and always beats a concurrent edit** — a tombstone is not a value LWW can overwrite. The losing editor gets their text handed back.
- Label membership converges through **IssueLabel link records**, not by merging a set-valued field.
- The server assigns an Issue Key on first sync; the protocol must return it so the client can replace its local placeholder.

## Inherited constraints (from resolved ticket 06)

The envelopes are already fixed by [ADR 0005](../../../docs/adr/0005-two-write-paths-one-concurrency-model.md) and ticket 06's resolution; this ticket designs the semantics inside them, not the shapes.

- Push returns **200 with a per-operation result array**; three outcomes — `applied`, `rejected`, `superseded`. Designing conflict handling means defining exactly when each is chosen.
- Operations carry an `opId` distinct from `entityId` for retry dedupe; define the dedupe window and its persistence.
- Pull is **one unified change stream** across entity types, ordered causally, with an **opaque server sequence watermark** (not a timestamp) and first-class tombstone entries. Define how that sequence is allocated and what guarantees it gives under concurrent writes.
- Pull **echoes the client's own writes back**; define how a client reconciles an echo against its own pending queue without double-applying.
- Push response carries the current watermark so a client can pull from exactly there.
- Caps: 500 operations / 5MB per batch; the client chunks and must preserve causal order across chunk boundaries.

## Inherited constraints (from resolved ticket 07)

- A **401 on sync push is a top-level failure, never a per-operation `rejected`**. The pending queue is preserved intact and sync enters a "needs re-authentication" state; auth failure must never quarantine an operation, because the writes are valid and only the session is not.
- `deviceId` in the push envelope is bound to the session token at login.
- Sessions have a 60-day idle expiry renewed on use, so the protocol should not assume a token survives an arbitrarily long offline period.

## Inherited constraints (from resolved ticket 12)

- Issue and Comment now carry **`via: human | agent`**, set server-side at creation and **immutable** — it never participates in per-field last-write-wins and never appears in a PATCH.

## Inherited constraints (from resolved ticket 05)

Storage and queue are settled in [ADR 0008](../../../docs/adr/0008-grdb-client-storage-and-offline-queue.md); this ticket designs the protocol over them.

- The queue's `opId` **is** the wire `opId` (ticket 06), so server-side retry dedupe and local queue identity are the same value.
- Queued payloads are **Merge-Patch shaped**, so replay is a direct translation, not a re-derivation.
- **Causal dependencies are derived** from a small pure function in Core (comment→issue, issueLabel→issue and label, issue→project) rather than stored as edges. The protocol must not assume a stored dependency graph.
- Operations coalesce **within one entity's own run while unsent** — never across a delete, never reordering across entities. The protocol sees a queue that has already been coalesced.
- **A pull delivering a tombstone for an entity with pending edits drops those operations as superseded-by-deletion, not quarantined** — there is nothing to retry against. Define how that is reported alongside the three push outcomes.
- Local display state is **base record + pending operations applied on read**, so a pull that rewrites the base must not be assumed to have discarded local edits.

## Resolution

Semantics inside envelopes already fixed by [ADR 0003](../../../docs/adr/0003-identity-and-conflict-resolution.md), [ADR 0004](../../../docs/adr/0004-offline-write-failure-contract.md) and [ADR 0005](../../../docs/adr/0005-two-write-paths-one-concurrency-model.md). No new ADR; ADR 0005 was **amended** to narrow `superseded`, and ticket 04's batch-atomicity wording was **corrected**.

### Watermark

**A change-cursor table, not an append-only log**: one row per entity — `(entityType, entityId, seq)` — `seq` from a monotonic counter, **upserted inside the same write transaction that changes the entity**. Pull is `WHERE seq > :since ORDER BY seq`, joined to current records.

An append-only log yields five rows for an entity edited five times and returns the same current record five times; LWW convergence only cares about the endpoint, not intermediate states. Upserting bounds the table at one row per entity.

**Guarantee: at-least-once delivery, never missed.** If an entity's `seq` jumps forward mid-pagination the client may see it twice — harmless, since applying a base record is idempotent — but it can never be skipped, because a row only ever moves *ahead* of the cursor.

### Push outcomes — when each fires

Under receipt-time arbitration (ADR 0003) the operation that arrives last always has the newest timestamp, so it always wins. `superseded` is therefore **much narrower** than it might sound:

- **`applied`** — valid, target not in a terminal state; written and stamped with server receipt time.
- **`rejected`** — validation failure, unknown reference, permission denied. Anything where retrying this payload cannot succeed without user repair.
- **`superseded`** — **the target entity is tombstoned**, already or by an earlier operation in the same batch. Deletion and future terminal states only; not ordinary field races.

### The stale-clobber problem, and why it is solved client-side

Pure receipt-time LWW means a three-day-old offline edit silently clobbers newer edits made while its author was away. The tempting fix — having each operation carry the base field timestamp it was edited against, and superseding when the server has moved on — **is optimistic concurrency, which ADR 0005 deliberately rejected** because reject-on-conflict on one path plus LWW on the other makes semantics depend on which client you used.

**So the server keeps pure receipt-time LWW — one model, unchanged — and detection lives in the client, advisorily.** On pull, a client can see that the base underneath a pending operation changed while it was offline, and warn *before* pushing: "this issue changed while you were offline; your edit will overwrite X." Users get conflict awareness; the server keeps one concurrency model.

Recorded so it is not re-litigated by drift: moving detection server-side is a legitimate alternative, but it requires amending ADR 0005 and ADR 0003 explicitly.

### Batching

- **One transaction per operation. A batch is a round-trip optimisation, not an atomicity boundary.** A single-transaction batch would let one rejected operation roll back the rest, violating ADR 0004's no-head-of-line-blocking rule.
- The shutdown guarantee comes from **idempotent replay**, not batch atomicity: interrupted mid-batch, some operations are applied and some are not; the client retries the identical batch, already-applied `opId`s dedupe, the rest apply. The invariant is "replay is safe".
- **The queue is topologically sorted once, globally, and batches are cut from that order**, so causal order across chunks holds by construction rather than by a boundary rule.
- **Batches are sent strictly sequentially, never concurrently** — two in flight risks the second's dependencies still being unapplied from the first.
- A transport-level failure retries the batch whole. A batch containing a rejected operation still advances; only its causal dependents are held back.

### Dedupe

**`opId` records are retained indefinitely**, consistent with tombstones (ADR 0003). A bounded window looks tidier but fails exactly where it matters: the queue survives session expiry (ticket 07), so a client can legitimately return after any offline period and replay operations older than any window, producing silent duplicates. Cost is a UUID and an integer per operation ever performed.

### Echo reconciliation

**One invariant: applying a pull only ever writes the base record, and never touches the pending queue.** The queue is mutated exclusively by push results. Since display is base-plus-pending (ADR 0008), an echo of your own write is harmless — base absorbs it, and the pending operation either re-applies identically on top or has already been removed by its push result. No sequence bookkeeping, no per-device filtering, no "is this mine?" test.

### Pull application

- **Apply a page's records and advance the stored watermark in one `write { }` transaction**, never advancing before applying. Advance-then-apply with a crash between permanently skips a page, and the client believes it is up to date while silently missing records forever.
- **The client's schema does not enforce foreign keys on sync-populated tables.** Pull is ordered by *change* time, not causal time, so an issue edited yesterday sits at a high `seq` while a year-old comment on it sits at a low one — the comment can arrive hundreds of pages before its issue. Orphans are stored and simply not displayed until their parent arrives; display queries join from Issue outward, so an orphan is invisible rather than broken, and resolves the moment its parent lands. Having the server emit causal order per page does not work: causal and `seq` order genuinely conflict, and a parent could still fall on a later page. **Convergence saves us here, not ordering.** This is a deliberate schema decision — anyone later "fixing" the missing foreign keys breaks first sync.
- **Dependents of a rejected operation are skipped lazily at batch-build time, not marked.** If the user repairs the ancestor, dependents become eligible again automatically; eager marking would need an un-marking sweep, a second state machine that can drift. ADR 0004's wording describes the observable behaviour, which lazy derivation produces exactly.

### First sync and recovery

- **The app is usable during first sync.** Each page applies transactionally, so the store is consistent-but-incomplete at every page boundary — show a syncing banner and let the user browse what has arrived. Blocking until complete feels broken on any Instance with real history.
- **Full-resync escape hatch**: a client whose watermark the server does not recognise (restored-from-backup server, corrupted local state) clears its base records and re-pulls with `since` omitted. **A full resync must never clear the pending queue** — that is unsent user work with nothing to do with base state.

### Triggers

| Trigger | Behaviour |
| --- | --- |
| App becomes active | Pull + push |
| Manual pull-to-refresh | Pull + push |
| Local write | Debounced push, ~2s idle |
| Network regained (`NWPathMonitor`) | Push |
| iOS / iPadOS background | `BGAppRefreshTask` — opportunistic, **no timing guarantee**, and the UI must never imply otherwise |
| macOS while running | Timer, 5 minutes. No background daemon |

Explicitly out per ADR 0001: push notifications, long-polling, and any persistent connection.

## Amendment (2026-09-08, from ticket 09)

**The watermark is `epoch:seq`, not `seq` alone**, and a **stale epoch is a third trigger for the full-resync escape hatch** already defined above — alongside an unrecognised watermark and corrupted local state. The rule that a full resync never clears the pending queue applies unchanged.

Reason: `issues-server restore` rewinds the sequence counter, reusing numbers for entirely different changes. Without an epoch, a client holding a high watermark is silently and permanently cut off from further changes — it sees empty results forever and reports no error. The epoch converts that into a one-time resync.
