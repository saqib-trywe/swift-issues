# Native app scope & UX boundaries per platform

Type: prototype
Status: resolved

Blocked by: 01, 06

## Question

Decide how much UI/UX diverges across macOS, iPhone, and iPad: does macOS get a richer multi-pane, keyboard-driven interface while iPhone/iPad get simplified single-column views, or is there one shared SwiftUI layer with platform-specific chrome only? Build a rough prototype (outline or stub SwiftUI views) of the core Issue-list-and-detail flow on at least two platforms to react to before locking this. Builds on the resolved [Domain model v1](../issues/01-domain-model-v1.md) and [HTTP API contract design](../issues/06-http-api-contract-design.md).

## Inherited constraints (from resolved tickets 01 and 06)

- Offline-created Issues have **no Issue Key until first sync** — every list and detail view needs a placeholder state for it.
- A field holding a leniently-decoded **`unknown` enum value is read-only** in that client: disable the control rather than offer a rewrite that would clobber a value the client cannot represent.
- Two states need somewhere to live in the UI, or the sync guarantees are void: **quarantined** operations (ADR 0004 "needs attention") and **superseded** edits (ADR 0001 — show the user the winning value and hand back their losing text).
- List views should use `?expand=labels,assignee`; the unexpanded shape is an N+1.
- `dueDate` is a timezone-free calendar date and must not be rendered through a timezone-converting formatter.

## Inherited constraints (from resolved ticket 07)

- The macOS app is the **primary place personal access tokens are minted** — there is no web UI — so it needs token management (create, label, list, revoke, last-used) and an Admin view of others' tokens.
- Needs a **"needs re-authentication"** state that preserves the pending queue and prompts login, distinct from the quarantine surface.
- **Logout with a non-empty pending queue must warn**, state how many unsynced changes exist, offer to sync first, and treat proceeding as an explicit destructive confirmation. Logout clears the local replica.
- Needs a device/session list showing concurrent sessions with individual revocation.

## Inherited constraints (from resolved ticket 12)

- Issues and Comments carry **`via: human | agent`** and need visible attribution — the whole point of the field is answering "which of these did the bot file?" at a glance.
- Token management in the macOS app must offer the **`agent` and `agent-readonly` kinds** alongside human tokens, and make clear that agent tokens hold less authority than their owner.

## Inherited constraints (from resolved ticket 05)

- **Minimum deployment target is OS 26** ([ADR 0008](../../../docs/adr/0008-grdb-client-storage-and-offline-queue.md)), applying the latest-*released*-only policy literally. Do not design around OS 27 APIs.
- **No `@Query`.** Storage is GRDB, so lists observe via a small `@Observable` wrapper over `ValueObservation.values(in:)` — roughly a day of work that is budgeted, not free. GRDBQuery is deliberately not a dependency.
- Displayed values are **the server base record with pending operations applied on read**, which means the UI can always answer "which fields are locally dirty" — use that for conflict presentation rather than inventing a parallel dirty-tracking mechanism.
- Needs a **superseded-by-deletion** message distinct from both quarantine and ordinary superseded: the user's edits are gone because the entity was deleted, and there is nothing for them to repair.

## Inherited constraints (from resolved ticket 08)

- **An advisory pre-push conflict warning is a required surface, not a nicety.** The server does pure last-write-wins, so the *only* place a user learns their offline edit is about to overwrite newer work is the client, before pushing ([ADR 0005 amendment](../../../docs/adr/0005-two-write-paths-one-concurrency-model.md)). Without it, stale edits clobber silently.
- **The app must be usable during first sync** — pages apply transactionally, so the store is consistent-but-incomplete at every boundary. Show a syncing banner and let the user browse what has arrived; blocking feels broken on any Instance with history.
- **Background refresh on iOS/iPadOS is `BGAppRefreshTask` with no timing guarantee.** The UI must never imply data is current — no "last updated 2 minutes ago" phrasing that a missed refresh turns into a lie.
- Records whose parent has not yet arrived are stored but must not be displayed; display queries join from Issue outward. This is by design, not a bug to fix.
- The "needs attention" count includes operations blocked behind a quarantined ancestor, computed on the fly rather than read from a column.
- `superseded` now means **superseded-by-deletion only** — the message is "the issue was deleted, here is your text back", never "someone else edited this field".

## Inherited constraints (from resolved ticket 09)

- The watermark is now **`epoch:seq`**, and a stale epoch (after a server restore) forces a **full resync**. The app needs a non-alarming way to show a full resync in progress — it is a normal recovery, not an error — and it must not clear the pending queue.
- macOS 26, Apple silicon only.

## Resolution

**Variant C — adaptive core.** Shared components and one view model, composed differently per platform. No ADR: this is UI structure over decisions already recorded, and the one genuinely load-bearing consequence (the five sync surfaces are built once) is a direct application of ADR 0004, 0005 and 0008 rather than a new choice.

Prototype: [../prototype/PROTOTYPE-issue-list-detail.html](../prototype/PROTOTYPE-issue-list-detail.html) — a throwaway HTML sketch with switchable variants and toggles for each sync state. Kept as the primary source for this decision. (Normally this would be captured on a throwaway branch; **this repo is not a git repository**, so it lives in `prototype/` with this pointer instead.)

### The verdict, and what decided it

Not aesthetics — **the five required sync surfaces**. Ticket 08's advisory pre-push conflict warning, ADR 0004's quarantine queue, ADR 0005's superseded-by-deletion, ticket 09's full-resync progress, and ticket 07's needs-re-authentication are all **required surfaces, not decoration**: if they are absent the sync guarantees are void. Toggling them on in the prototype is what settled the question.

- **A (unified)** was rejected on sight: the Mac gets a card list in a 940px window with nothing to sort and no keyboard affordances. It is an iPad app on a desktop.
- **B (divergent)** is best-in-class per platform but means **designing and maintaining each of the five sync surfaces twice** — and those are precisely the surfaces where a subtle divergence becomes a correctness problem rather than a cosmetic one.
- **C** keeps one behaviour layer and two compositions: the sync surfaces are written once and *placed* twice.

### Structure

**Shared (one implementation, all platforms)**

| Type | Responsibility |
| --- | --- |
| `IssueListModel` | `@Observable`, wrapping `ValueObservation.values(in:)` — the hand-written wrapper ADR 0008 budgeted in place of `@Query` |
| `IssueDetailModel` | Same, single issue plus comments |
| `SyncStatusView` | **All five sync states**, one implementation, stackable |
| `IssueRowContent` | Title, key, status, priority, assignee, labels, `via`, dirty marks |
| `IssueDetailContent` | Field stack + comment thread |
| `IssueKeyLabel` | Renders `PROJ-142` **or the `PROJ-•` placeholder** for an unsynced local issue |
| `StatusPill`, `PriorityLabel`, `LabelChip`, `ViaBadge`, `DirtyIndicator` | Atoms |

**Per-platform composition (thin)**

- **macOS** — `NavigationSplitView` with sidebar, a sortable `Table` of `IssueRowContent`, and a **detail inspector**. Keyboard-first: `⌘N` new, `⌘F` filter, `⌘⌫` cancel, arrow-key navigation, type-ahead. This is also the **only** platform with token management (create/label/list/revoke, `agent` and `agent-readonly` kinds, Admin view of others' tokens) and the device/session list — there is no web UI, so the Mac carries them.
- **iPhone** — `NavigationStack`, single column of `IssueRowContent` cards pushing to a full-screen `IssueDetailContent`, tab bar with a **badged Inbox** for the needs-attention count.
- **iPad** — the **macOS composition at touch sizes**, not the iPhone one: `NavigationSplitView` two-column, since the screen affords it and a phone layout on an iPad wastes it. It does *not* get the Mac's token/session administration.

### Rules the composition must honour

- **The five sync surfaces come from `SyncStatusView` on every platform.** Do not reimplement one per platform — that is the failure mode variant B was rejected to avoid.
- **`superseded` means superseded-by-deletion only.** The copy is "this issue was deleted; here is your text back" — never "someone else edited this field", which cannot happen under receipt-time LWW.
- **Never imply data is current.** iOS background refresh is `BGAppRefreshTask` with no timing guarantee, so no "updated 2 minutes ago" phrasing that a missed refresh turns into a lie. Show sync *state*, not freshness.
- **Fields holding an `unknown` enum value render read-only and disabled**, never as a picker that would clobber a value the client cannot represent.
- **Dirty state is derived** from base-plus-pending (ADR 0008), never tracked separately.
- **Records whose parent has not arrived are not displayed** — queries join from Issue outward. By design (ticket 08), not a bug.
- **`dueDate` renders through a calendar-date formatter**, never a timezone-converting one.
- **The app is usable during first sync**, and a full resync after an epoch change is presented as normal recovery, not an error.
- **Logout with a non-empty queue** warns with the count, offers to sync first, and treats proceeding as explicit destruction.

### Deliberately not diverging

Filtering, search, sorting semantics, all copy, and every sync surface are shared. Divergence is confined to **layout container, input affordances, and the Mac-only administration surfaces**.
