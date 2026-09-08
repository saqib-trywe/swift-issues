# Two write paths, one concurrency model

The API is deliberately **two contracts**: a resource-shaped REST surface (`/api/v1/...`) that the CLI, MCP interface and scripts use, and a narrow **sync pair** (`POST /api/v1/sync/push`, `GET /api/v1/sync/pull`) used only by the offline-first native apps. They have irreconcilable shapes — sync needs batched, causally ordered writes with **per-operation** outcomes (ADR 0004 requires one rejected operation not to fail its batch) and a delta stream carrying tombstones, while REST needs one resource per request and a single status code. Crucially, both paths share **one** concurrency model: last-write-wins arbitrated by the server's receipt timestamp (ADR 0003), with no `ETag`/`If-Match` optimistic concurrency anywhere.

## Considered Options

- **One contract, REST only.** Sync would become N round trips with no batch atomicity and nowhere to report per-operation failure. Rejected.
- **One contract, sync only.** The CLI would have to maintain a local replica just to file an issue. Rejected.
- **`If-Match` on the REST path**, since a 412-on-conflict is the conventional REST answer and a reviewer will expect it. Rejected deliberately: it would put reject-on-conflict and last-write-wins over the same rows, so the semantics a user got would depend on which client they happened to use. One imperfect model beats two contradictory ones. JSON Merge Patch already bounds the damage — a request can only clobber fields it explicitly names.

## Consequences

- The two paths must not drift. They are generated from the same DTOs and validation in the shared Core package; that shared origin is the entire mitigation, and splitting them into separately-maintained payload types would quietly undo this decision.
- Sync push **always returns 200 with a per-operation result array**; top-level 4xx is reserved for a malformed batch or auth failure.
- Operation outcomes are **three, not two**: `applied`, `rejected` (quarantine), and **`superseded`** (lost last-write-wins, carrying the current server record). Without `superseded` there is nowhere to express "your edit was valid but someone beat you", and ADR 0001's promise to surface the losing edit rather than drop it would be unimplementable — it would report success while the user's text vanished.
- All mutation uses **JSON Merge Patch** (RFC 7386), which requires a three-state `Patchable<T>` in Core distinguishing an absent key from an explicit `null`. Swift's `Decodable` collapses both to `nil` by default; getting this wrong means either nothing can ever be unassigned, or every PATCH silently wipes the fields it didn't mention. It also aligns with per-field LWW: only keys present in a PATCH have their field timestamps bumped.
- Two CLI users editing the same field seconds apart: last one wins, no warning. Accepted at single-team scale.

## Amendment (2026-09-08, from ticket 08)

**`superseded` is narrower than this ADR's original wording suggests.** Under receipt-time arbitration ([ADR 0003](0003-identity-and-conflict-resolution.md)) the operation that arrives last always carries the newest timestamp, so it always wins — meaning `superseded` never fires for an ordinary field race. It fires when **the target entity is tombstoned**, already or by an earlier operation in the same batch: deletion and future terminal states only.

The consequence this ADR's "one concurrency model" rule forces, recorded so it is not re-litigated by drift: a three-day-old offline edit silently clobbers newer edits made while its author was away. The obvious fix — carrying the base field timestamp per operation and superseding when the server has moved on — **is optimistic concurrency, which this ADR rejected**, and adopting it on the sync path only would recreate exactly the split semantics the decision exists to prevent. Detection therefore lives **in the client, advisorily**: on pull, a client can see that the base underneath a pending operation changed while it was offline and warn before pushing. Moving detection server-side remains legitimate, but requires amending this ADR and ADR 0003 explicitly.
