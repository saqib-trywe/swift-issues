# Domain model v1: entities, fields, relationships

Type: grilling
Status: resolved

## Question

Nail down the v1 domain model: the exact entities (Project, Issue, Comment, User, Label?), their fields, relationships/cardinalities, and invariants. Confirm against the agreed v1 floor (Project → Issue [title, description, status, assignee, reporter, priority, labels, due date] → Comment; fixed status set) and CONTEXT.md's existing glossary — sharpen or extend as needed. Open sub-questions to resolve here:

- Is Label a free-form string or its own managed entity with a project-scoped set of values?
- Is priority a fixed enum, or an ordered/project-configurable list?
- Does an Issue have a parent/child or "blocks/blocked-by" relationship to other Issues, or is that out of scope (it borders on the epics/sprints territory already ruled out)?
- Can a Comment be edited or deleted, and if so, how does that interact with offline sync (an edit made offline to a Comment someone else already deleted)?
- What are the required vs optional fields on Issue creation?

Update `CONTEXT.md` as terms crystallize. Add an ADR if any resulting choice is hard to reverse or non-obvious.

## Resolution

Locked. Hard-to-reverse mechanics are recorded separately in [ADR 0003](../../../docs/adr/0003-identity-and-conflict-resolution.md) (identity, clocks, link records, tombstones) and [ADR 0004](../../../docs/adr/0004-offline-write-failure-contract.md) (causal replay, quarantine). Vocabulary is in [CONTEXT.md](../../../CONTEXT.md).

### Entities

Every entity's primary key is a client- or server-generated **UUIDv7**. Every entity carries `createdAt` and `updatedAt` as UTC instants, stamped by the server on receipt; every syncable entity except User and Project also carries a nullable `deletedAt` tombstone.

**User** — `id`, `email`, `displayName`, `role: Member | Admin`, `active: Bool`.
Never deleted, only deactivated: Users are referenced as reporter, assignee and comment author permanently.

**Project** — `id`, `key`, `name`, `description`, `archived: Bool`.
`key` is `[A-Z0-9]{2,10}`, unique per Instance, and **immutable** — it is baked into every Issue Key. Archived rather than deleted.

**Issue** — `id`, `key: String?`, `projectId`, `title`, `description`, `status`, `priority`, `reporterId`, `assigneeId: UUID?`, `dueDate: CivilDate?`, `via`, `deletedAt`.
`key` is null until first sync (ADR 0003). `reporterId` is set at creation and immutable. `assigneeId` is single and optional. `dueDate` is a calendar date — no time, no timezone. `description` is Markdown source. Carries per-field timestamps for its six mutable scalars: `title`, `description`, `status`, `priority`, `assigneeId`, `dueDate`.

**Label** — `id`, `projectId`, `name`, `color`, `deletedAt`.
`id` is UUIDv5 derived from (`projectId`, lowercased trimmed `name`) so concurrent offline creates converge (ADR 0003).

**IssueLabel** (link record) — `id`, `issueId`, `labelId`, `deletedAt`.
Label membership is a record, not a field, so concurrent adds both survive.

**Comment** — `id`, `issueId`, `authorId`, `body`, `via`, `deletedAt`.
`body` is Markdown source; `updatedAt` surfaces as "edited". Versioned per record, not per field. **Deletion clears `body`**, retaining only ids and timestamps for convergence — a deleted comment vanishes from the thread rather than leaving a marker. This is a sensible default, not a security guarantee: backups and long-offline clients still hold the old text.

### Fixed enumerations

- **Status**: `todo`, `inProgress`, `done`, `cancelled`. Each carries a category (`open` / `closed`). `cancelled` is closed but distinct from `done`, so abandoned work doesn't read as completed work.
- **Priority**: `none`, `low`, `medium`, `high`, `urgent` — ordered. Defaults to `none`, deliberately: a tracker where everything is born "medium" teaches people that priority is noise.
- **Role**: `member`, `admin`.

All three **decode leniently** into an `unknown(String)` case, preserved verbatim on round-trip and rendered as a neutral chip. Self-hosted means an admin can upgrade the server while clients in the field lag by weeks; strict decoding would let one server upgrade break sync for the entire installed base at once. This is distinct from the project's latest-released-only Swift/OS policy, which governs build-time versions the team controls.

### Creation requirements

`title` is the only field a human must supply. `projectId` and `reporterId` are required but implicit from context and auth; `status` defaults to `todo`, `priority` to `none`. Optional: `description`, `assigneeId`, labels, `dueDate`.

### Invariants the server enforces

- `title` non-empty after trimming, ≤512 characters.
- `description` and Comment `body` ≤64KB; Comment `body` non-empty.
- `assigneeId` must reference an existing **active** User **at write time only** — deactivating someone later does not retroactively invalidate their existing assignments.
- A Label may only be applied to an Issue in the Project that owns it.
- Project `key` matches `[A-Z0-9]{2,10}`, unique per Instance, immutable.
- Archived Projects reject **new** Issues but still permit edits to existing ones, so stragglers can be closed out.
- Any reference to an unknown id is rejected outright (ADR 0004).
- **Allowed**: `dueDate` in the past. Overdue is a normal state and backfilling is common.

Validation lives in the shared Core package and runs client-side optimistically before the server re-checks it authoritatively.

### Permissions

- Issue delete: reporter or Admin. Members' normal "make it go away" path is setting status to `cancelled`; hard deletion should stay rare.
- Comment edit: author only. Comment delete: author or Admin.
- Project create/archive and User management: Admin (per CONTEXT.md).

### Deliberately excluded from v1

- **Issue-to-Issue relationships** — no parent/child (that is epics in disguise) and no blocks/blocked-by. Dependency links drag in cycle detection and a graph to render, and under offline sync two clients can independently create a cycle discovered only at merge. Cross-references are plain text mentions of an Issue Key.
- **Moving an Issue between Projects** — a key rewrite invalidates every external reference (commit trailers, chat messages, bookmarks), project-scoped labels would need remapping, and two clients could concurrently move one Issue to two Projects. Workaround: cancel and recreate. Accepted papercut: people do misfile issues.
- **Attachments** — not a field but a subsystem: blob storage, upload progress, offline caching of binaries, size limits, and a backup story measured in gigabytes. Accepted cost: this will be v1's most-missed absence, since people paste screenshots into trackers constantly. The API contract should leave room rather than pretend otherwise.
- **Multi-assignee**, configurable priorities or statuses, per-project workflows, rich-text/WYSIWYG editing.

## Amendment (2026-09-07, from ticket 12)

**Issue and Comment gain `via: human | agent`.** Set server-side from the writing token's `kind` at creation, immutable thereafter, and therefore never a participant in per-field last-write-wins.

This reopens a locked model deliberately. Without it, work an agent files under its owner's identity is indistinguishable from work the human filed — "which of these did the bot open?" is a question that arrives in the first week, and retrofitting the field later means backfilling rows that have no answer. The rejected alternative was convention only (instructing agents via tool descriptions to sign their comments), which nothing enforces and which models reliably drop.
