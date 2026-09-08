# Client-side local storage landscape (macOS / iOS / iPadOS)

Research for [ticket 03](../issues/03-local-storage-research.md); feeds the decision in [ticket 05](../issues/05-choose-local-storage-offline-queue.md). **No decision here.**

Date of survey: 2026-09-07. Every substantive claim is cited; where a claim rests on forum/radar chatter rather than Apple documentation it is marked as such with a confidence level.

## Baseline: what "latest released" means today

| Thing | Latest **released** as of 2026-09-07 | Note |
| --- | --- | --- |
| Swift | **6.3** (6.3.3 toolchain), released 2026-03-24 | [swift.org/blog/swift-6.3-released](https://www.swift.org/blog/swift-6.3-released/), [swift.org/install/macos](https://www.swift.org/install/macos/) |
| Xcode | **26.6** (17F113), 2026-06-25 — ships **Swift 6.3** + the 26.5 SDKs | [Xcode 26.6 release notes](https://developer.apple.com/go/?id=xcode-26_6-sdk-rn), [developer.apple.com/news/releases](https://developer.apple.com/news/releases/) |
| macOS | **Tahoe 26.6.2** (25G83), 2026-08-17 | [developer.apple.com/news/releases](https://developer.apple.com/news/releases/) |
| iOS / iPadOS | **26.6.1** (23G83), 2026-08-17 | [developer.apple.com/news/releases](https://developer.apple.com/news/releases/) |
| Next major | iOS/iPadOS/macOS **27** at beta 8 (2026-08-31); Xcode 27 beta 6 ships Swift 6.4 | [developer.apple.com/news/releases](https://developer.apple.com/news/releases/), [Xcode 27 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) |

**Correction (2026-09-07, during write-up).** This table originally recorded Xcode 26.6 as shipping Swift 6.2. It ships **Swift 6.3** — Swift 6.2 was Xcode 26.0. Verified against the [Xcode 26.6 release notes](https://developer.apple.com/go/?id=xcode-26_6-sdk-rn) and the [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes). This matters because as originally written it implied the Apple app targets were pinned a minor version behind the standalone toolchain used by the server and CLI, which would have put a false constraint on the shared Core package (ADR 0002). There is no such split: Xcode-built and toolchain-built targets are both on the 6.3 line.

**Note on the 6.3 release date.** This file cites 2026-03-24 (the swift.org announcement); the sibling file [02-server-framework-landscape.md](02-server-framework-landscape.md) cites 2026-03-27 (the `swift-6.3-RELEASE` GitHub tag). These are two different events, not a contradiction.

**Timing caveat that matters for this decision.** OS 27 is at beta 8 and, on Apple's usual cadence, ships within weeks. A "latest-released-only" project starting now will be building against **26** but shipping onto **27**. Anything below that depends on a SwiftData API added in the June 2026 (OS 27) wave — notably `ResultsObserver` and `HistoryObserver` ([SwiftData updates](https://developer.apple.com/documentation/updates/swiftdata)) — is a bet on 27, not something available on today's released OS.

## Summary

**Shortlisted: SwiftData, GRDB, hand-rolled SQLite.** Dropped with reasons: Core Data used directly (its `NSManagedObjectContext` is annotated `NS_SWIFT_SENDABLE`, so the compiler *cannot* enforce queue confinement — strictly weaker than SwiftData) and SQLite.swift (its own manifest declares `swiftLanguageModes: [.v5]`, and it is still 0.x after 11 years).

- **All three shortlisted options pass the Swift 6 strict-concurrency gate, but not in the same way.** GRDB is compiler-enforced at the `read`/`write` closure boundary; SwiftData's `ModelContext` is deliberately non-`Sendable` so the compiler stops you moving it; hand-rolled passes *by assertion*, since `OpaquePointer` is non-`Sendable` (SE-0331) leaving actor confinement the compiler can't verify, or `@unchecked Sendable`. Ticket 05 must state which reading of the "hard gate" it means, because the three are not equivalent under the stricter one.
- **The largest capability gap is where ADR 0004's topological replay ordering lives.** On SQLite it is a recursive CTE — declarative, engine-evaluated, testable against a SQL fixture. SwiftData has **no raw-SQL escape hatch at all** (the on-disk format is a private Core Data detail), so ordering and quarantine's transitive closure become Swift-side graph walks or denormalised columns. Same for the partial index that keeps quarantine from head-of-line blocking.
- **SwiftData's weakest axis is temporary and schedule-dependent.** Its non-SwiftUI observation API (`ResultsObserver`/`HistoryObserver`) is OS 27-only, and this project writes on a background actor then refreshes the UI. That makes the storage choice **coupled to the minimum-deployment-target decision**; GRDB and hand-rolled are unaffected by it.
- **SwiftData's real advantage is UI velocity**, and it is not small: `@Query` + `@Model` removes a layer that GRDB replaces with either pre-1.0 GRDBQuery (unpushed since March 2025) or about a day of `@Observable` wrapper around `ValueObservation`.
- **Apple-platform lock-in is decisive if shared-Core reuse is real.** SwiftData and Core Data cannot run on Linux; GRDB has since 7.10.0 and raw SQLite always could. Establish whether the CLI/MCP surfaces or CI ever need the same store before weighting this.

Not differentiators, so ticket 05 need not argue them: CloudKit (off in every option), hand-writing the sync engine (required under all three), per-field timestamps and tombstones (columns in every option), SQLite's durability (same engine underneath), and migrations (all workable, differing in ceremony).

---

## SwiftData

Apple's declarative persistence framework, `@Model` macro over a Core Data stack (SQLite on disk). Shipped iOS 17 / macOS 14; three years old at time of survey. Availability metadata below is taken from the docs' own `availability` blocks.

### Maturity on latest released OS

Feature waves, per [SwiftData updates](https://developer.apple.com/documentation/updates/swiftdata):

- **June 2024 (iOS 18)** — `#Index` (single and compound), `#Unique`, persistent history (`fetchHistory(_:)`, `deleteHistory(_:)`, `HistoryProviding`), and the `DataStore` protocol for custom backing stores.
- **June 2025 (iOS 26)** — model class **inheritance** via `@Model`, and `HistoryDescriptor.sortBy`.
- **June 2026 (iOS 27, still beta)** — `ResultsObserver` (`@Query` equivalent outside SwiftUI), `HistoryObserver` (react to store changes, filterable by model type and transaction author), `sectionBy` query macros, and the `.codable` attribute option for types you don't own. Covered in [What's new in SwiftData, WWDC26](https://developer.apple.com/videos/play/wwdc2026/274/); `ResultsObserver.FetchDescriptor` carries `iOS: 27.0.0 -` availability ([docs](https://developer.apple.com/documentation/swiftdata/resultsobserver/fetchdescriptor)).

Read that as: **the "observe query results from a non-SwiftUI actor" story only exists on OS 27.** On released OS 26 the supported change-notification surface is `ModelContext.willSave` / `didSave` `Notification`s plus manual persistent-history polling ([ModelContext docs](https://developer.apple.com/documentation/swiftdata/modelcontext)). For a sync engine that writes on a background actor and must refresh UI, that gap is the single most consequential 26-vs-27 difference.

Still rough: predicate support is a runtime-checked subset (below), to-many ordering is unspecified (below), and there is no supported raw-SQL escape hatch — the on-disk format is a Core Data implementation detail, so no FTS5, no `EXPLAIN`, no hand-written recursive CTE.

### Concurrency / Sendable

The documented shape is precise and worth quoting from conformance lists rather than tutorials:

- `ModelContext` conforms to `Equatable` and `SendableMetatype` — **not `Sendable`** ([ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)).
- `PersistentIdentifier` **is** `Sendable`, `Hashable`, `Codable` ([PersistentIdentifier](https://developer.apple.com/documentation/swiftdata/persistentidentifier)).
- `FetchDescriptor` **is** `Sendable` ([FetchDescriptor](https://developer.apple.com/documentation/swiftdata/fetchdescriptor)).
- `ModelActor: Actor` with `modelContainer`, `modelContext`, `modelExecutor`, and a `subscript(_:as:)` for id→model lookup; `DefaultSerialModelExecutor` / `SerialModelExecutor` back it ([Concurrency support](https://developer.apple.com/documentation/swiftdata/concurrencysupport), [ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor)).

So the intended Swift 6 pattern is: one `@ModelActor` per background job, never let a `PersistentModel` cross an isolation boundary, pass `PersistentIdentifier` or a hand-written `Sendable` DTO instead. That is genuinely actor-shaped, and it is the pattern Apple documents.

The friction, all of it forum-level rather than documented:

- **`@ModelActor`'s generated initialiser is `nonisolated`** and constructs the `ModelContext` on the caller — so `MyActor(modelContainer:)` called from `@MainActor` does its setup work on the main thread. Reported repeatedly (["SwiftData does not work on a background thread"](https://developer.apple.com/forums/thread/736226), ["@ModelActor with init parameters"](https://forums.swift.org/t/modelactor-with-init-parameters/76981) — the latter shows the "Actor-isolated property cannot be mutated from a nonisolated context" wall you hit trying to add stored state to a model actor). **Confidence: medium-high** that the behaviour is real (multiple independent reports, consistent with the macro's expansion); **low** that it is considered a bug by Apple — no staff acknowledgement or release-note entry found.
- **Strict-concurrency warnings from `#Predicate` / `SortDescriptor` closures** in Complete-checking mode are reported as noise that does not become an error in Swift 6 language mode ([forum discussion](https://developer.apple.com/forums/thread/762178)). **Confidence: low-medium** — user reports, no Apple documentation.
- Multi-context writes still go through Core Data's merge machinery; SwiftData exposes no explicit "write transaction" isolation level, only `ModelContext.transaction(block:)` (run closure, then save) ([docs](https://developer.apple.com/documentation/swiftdata/modelcontext)).

### Relational querying (Projects / Issues / Comments)

Adequate for the shape this app needs, with caveats:

- `FetchDescriptor` gives `predicate`, `sortBy`, `fetchLimit`, `fetchOffset`, `includePendingChanges`, `propertiesToFetch`, `relationshipKeyPathsForPrefetching`; `fetchCount`, `fetchIdentifiers`, batched `fetch(_:batchSize:)` and `enumerate(_:batchSize:...)` for large sets ([FetchDescriptor](https://developer.apple.com/documentation/swiftdata/fetchdescriptor), [ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)).
- `#Index` (including compound) since iOS 18 covers the filter/sort paths an issue list needs ([SwiftData updates](https://developer.apple.com/documentation/updates/swiftdata)).
- **Predicates are a runtime-validated subset.** Constructs that compile fine can throw `unsupportedPredicate` at fetch time — e.g. force-unwrapping through an optional relationship (`$0.journal!.id! == x`) fails and must be rewritten as `if let` ([Apple forum thread 738157](https://developer.apple.com/forums/thread/738157), FB13202879). **Confidence: high** that the class of problem exists (widely reproduced, filed); the exact set of unsupported constructs is not documented anywhere authoritative, which is itself the risk.
- **Search**: no full-text index. String matching is `contains` / `localizedStandardContains` in a predicate, i.e. a scan. "Basic search" per the v1 floor is reachable; anything more wants FTS5, which SwiftData cannot reach.
- **To-many relationship ordering is not guaranteed.** Apple's docs never promise it; multiple reports describe relationship arrays coming back in varying order across reloads, with the standard workaround being an explicit sort key ([forum 734108](https://developer.apple.com/forums/thread/734108), [forum 735545](https://developer.apple.com/forums/thread/735545)). **Confidence: medium-high** on the behaviour, **high** on "there is no documented ordering guarantee to rely on."

### Fit against the locked offline requirements

- **Topologically ordered pending-op log (ADR 0004).** Modellable as a `PendingOperation` entity with an explicit sequence number plus a dependency edge (self-relationship or a parent-id column) — but SwiftData gives no help: no ordered relationships (previous point), no recursive query to compute a transitive dependency closure, so the topological walk and the "is any ancestor quarantined?" test must be done in Swift over fetched rows or maintained as denormalised columns.
- **Quarantine without head-of-line blocking (ADR 0004).** Straightforward as data: a `state` enum + `lastError` on the operation, and the "next sendable batch" is a `FetchDescriptor` with a predicate over state and dependency status. The awkward part is that SwiftData has no atomic "claim these rows" primitive — you rely on the sync work being confined to one `ModelActor`, which is fine given a single-writer design.
- **Per-field timestamps on six Issue scalars (ADR 0003).** Six extra `Date` attributes on `Issue`, or a small `Codable` composite attribute. Mechanically fine. Note SwiftData has no per-property change hook; you enforce "touch the timestamp when you touch the field" in your own model methods.
- **Indefinitely retained tombstones (ADR 0003).** A `deletedAt: Date?` column and a predicate on every read path. Note this means never calling `ModelContext.delete(_:)` for domain deletes, which puts you slightly against the framework's grain (cascade delete rules, `@Relationship(deleteRule:)` and the `.deny` rule all become unused).
- **Durability of the queue.** Autosave is on by default for the SwiftUI-environment context; a queue you cannot afford to lose wants `autosaveEnabled = false` and explicit `save()` / `transaction(block:)` at your own boundaries ([ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)).

### Migration / schema evolution

`VersionedSchema` + `SchemaMigrationPlan` + `MigrationStage` (lightweight and custom stages), available since iOS 17 ([SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)). This is the Core Data model-version mechanism with a Swift face: you keep every historical schema as a type in the binary forever. Serviceable, but heavier than "write a numbered SQL migration", and custom stages run arbitrary Swift over both old and new contexts.

### Apple-provided sync layer — status

There is **no Apple sync layer for a third-party server.** SwiftData's automatic sync is CloudKit only, implemented on `NSPersistentCloudKitContainer`, enabled via `ModelConfiguration(cloudKitDatabase:)` and disabled with `.none` ([Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)). Its schema constraints are instructive even though this project won't use it: CloudKit cannot enforce `@Attribute(.unique)`, requires **all relationships to be optional**, and does not support the `.deny` delete rule — Apple's own conflict story degrades the model to make server reconciliation tractable. Since this project syncs to its own HTTP API, the correct configuration is explicitly `cloudKitDatabase: .none`, and the entire sync engine (including everything in ADRs 0003/0004) is hand-written regardless of which storage layer wins.

---

## GRDB (SQLite)

`groue/GRDB.swift` — a SQLite toolkit: raw SQL, a type-safe query interface, record protocols over plain structs, migrations, and change observation.

### Maturity on latest released OS

- **Latest release 7.11.1, 2026-06-18.** Requirements as stated in the README: iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 7.0+, SQLite 3.20.0+, **Swift 6.1+ / Xcode 16.3+** ([README](https://github.com/groue/GRDB.swift/blob/master/README.md)). The Swift-version floor was raised deliberately in 7.9.0 ([CHANGELOG](https://github.com/groue/GRDB.swift/blob/master/CHANGELOG.md)).
- Project started 2015; **GRDB 7.0.0 shipped 2025-01-26** as the Xcode 16 / Swift 6 release, whose headline breaking change was adding missing `Sendable` conformances ([CHANGELOG](https://github.com/groue/GRDB.swift/blob/master/CHANGELOG.md), [GRDB 7 beta thread on forums.swift.org](https://forums.swift.org/t/grdb-7-beta/75018)).
- Repo health at survey time: MIT licence, ~8.6k stars, **7 open issues**, last push 2026-08-08 ([GitHub API](https://api.github.com/repos/groue/GRDB.swift)). Release cadence through 2026 is steady (7.8 → 7.11.1 between Oct 2025 and Jun 2026).
- It rides the **system SQLite** by default, so "maturity on the latest OS" is really SQLite's maturity — the most-deployed database engine there is ([sqlite.org](https://www.sqlite.org/mostdeployed.html)). Recent releases have been widening platform support to Android/Linux/Windows (7.10.0), which matters if the CLI/MCP surfaces ever want the same storage layer.
- Caveat on the ecosystem edge: **GRDBQuery**, the SwiftUI companion that provides the `@Query` equivalent, is at **0.11.0 (2025-03-15)** and has not been pushed since ([GitHub](https://github.com/groue/GRDBQuery)). It is pre-1.0 and less actively maintained than GRDB itself. GRDB core does not need it — `ValueObservation.values(in:)` is an `AsyncSequence` you can drive from your own observable model.
- Bus factor: nearly every PR in the 7.x release notes is authored by the original maintainer (`@groue`), with occasional outside contributions ([Releases](https://github.com/groue/GRDB.swift/releases)). Single-maintainer risk is real; it is offset by MIT licence and a stable, forkable codebase.

### Concurrency / Sendable

GRDB has an explicit, documented Swift 6 story — the library ships a whole DocC article on it ([Swift Concurrency and GRDB](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/SwiftConcurrency.md), [Concurrency](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md)):

- Two connection types: `DatabaseQueue` (serializes everything) and `DatabasePool` (WAL: parallel reads alongside one writer). Both expose the same `DatabaseReader`/`DatabaseWriter` API and the same SQLite isolation guarantees.
- `try await writer.write { db in ... }` and `read` are first-class async. **Async accesses honour task cancellation: a cancelled `Task` makes reads/writes throw `CancellationError` and rolls the transaction back.** That is exactly the structured-concurrency behaviour this project wants, and it is documented, not incidental.
- Data-race safety is enforced by the compiler at the closure boundary: in Swift 6 mode anything crossing in or out of a `read`/`write` closure must be `Sendable`. GRDB's own guidance is therefore **"records should be structs, not classes"** — the legacy `Record` base class is explicitly discouraged since GRDB 7.
- Actor-friendliness: `DatabaseWriter` is `Sendable`, so an actor (or any isolated type) can hold the connection and `await` through it. There is no framework-owned actor equivalent to `ModelActor` — the concurrency primitive is the connection's serialized/pooled access, not an actor. In practice that means a `SyncEngine` actor holding a `DatabasePool` composes cleanly; you do not inherit an executor you did not choose.
- Two documented strict-concurrency papercuts, both with stated fixes: shorthand closure notation (`writer.read(Player.fetchCount)`) warns unless you enable the `InferSendableFromCaptures` upcoming feature; and a `static let databaseSelection` must become `static var` computed ([SwiftConcurrency.md](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/SwiftConcurrency.md)).
- Reentrancy is a programmer error: a sync access nested inside another access is a fatal error ([Concurrency.md](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md)).

### Relational querying

This is GRDB's centre of gravity, and it exceeds what the v1 feature floor needs.

- Type-safe query interface (`Player.order(\.score.desc).limit(10).fetchAll(db)`), associations/joins, plus unrestricted raw SQL with SQL-interpolation-based injection safety ([README](https://github.com/groue/GRDB.swift/blob/master/README.md)).
- **FTS3 / FTS4 / FTS5** are first-class, including external-content tables, relevance ranking (`ORDER BY rank`), custom tokenizers, and pattern validation for untrusted user input ([Full-Text Search guide](https://github.com/groue/GRDB.swift/blob/master/Documentation/FullTextSearch.md)). If issue search ever needs to be more than a `LIKE` scan, the path exists without changing storage layers.
- JSON columns for `Codable` sub-structures ([JSON.md](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/JSON.md)).
- Observation: `ValueObservation` (values), `DatabaseRegionObservation` and `TransactionObserver` (transactions). 7.11.0 added an option to disable database change filtering in `TransactionObserver` ([release notes](https://github.com/groue/GRDB.swift/releases)).

### Fit against the locked offline requirements

Every ADR 0003/0004 requirement maps onto ordinary SQL, which is the point.

- **Topologically ordered pending-op log.** A `pending_operation` table with a monotonic `seq`, plus a `pending_operation_dependency` edge table; the "what can I send now?" query and the "quarantine the transitive closure" query are both recursive CTEs, which SQLite has supported since 3.8.3 ([sqlite.org/lang_with.html](https://www.sqlite.org/lang_with.html)). No Swift-side graph walk needed, and no risk of the ordering being an emergent property of an unordered collection.
- **Quarantine without head-of-line blocking.** A `state` column plus a **partial index** (`WHERE state = 'pending'`) makes "next N sendable ops" an index scan regardless of how many quarantined rows accumulate ([sqlite.org/partialindex.html](https://www.sqlite.org/partialindex.html)).
- **Atomicity of "apply optimistically + enqueue operation".** A single `try await writer.write { }` is one SQLite transaction covering both the local mutation and the queue append — the exact invariant an offline-first client must not lose. GRDB's Concurrency Rule 2 makes this the framework's stated responsibility model ([Concurrency.md](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md)).
- **Per-field timestamps on six Issue scalars.** Six nullable `INTEGER`/`TEXT` columns, or a JSON column. No framework opinion either way.
- **Indefinitely-retained tombstones.** A `deleted_at` column and either a filtered view or a partial index on live rows. `ViewRecords` support means the "live issues" view can be a first-class record type ([ViewRecords.md](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/ViewRecords.md)).
- Cost of that freedom: **you write and own the schema, the indexes, and the queue algorithm.** Nothing is generated from your Swift types; the record structs and the tables are two artefacts you keep in agreement yourself.

### Migration / schema evolution

`DatabaseMigrator`: named migrations registered in order, applied-migration bookkeeping stored in a reserved table inside the database, **each migration in its own transaction** with rollback on failure, deferred foreign-key checks during migration, `migrate(upTo:)` for tests, and `hasCompletedMigrations` / `hasBeenSuperseded` for "database too old / too new" checks ([Migrations.md](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md)). 7.8.0 added **merged migrations**, letting you collapse historical migrations without breaking installed clients ([release notes](https://github.com/groue/GRDB.swift/releases)). This is the most conventional and most auditable migration story of the three options — numbered SQL, forward-only, versioned in the file you can read.

### Notable limitations

- Third-party dependency with a single dominant maintainer (see above).
- No compile-time link between record structs and the schema: a column rename that you forget to mirror in the struct is a **runtime** decoding error, not a compile error. (Symmetric to SwiftData's runtime `unsupportedPredicate`, but the failure surface is different: GRDB fails at decode, SwiftData at query planning.)
- SwiftUI integration is a separate, less-maintained package if you want `@Query`-style property wrappers.
- You inherit SQLite's constraints directly — `ALTER TABLE` is limited (SQLite supports add/rename/drop column but not arbitrary type changes; the general recipe is create-new-table-and-copy, [sqlite.org/lang_altertable.html](https://www.sqlite.org/lang_altertable.html)) — though GRDB's schema-modification helpers wrap that recipe.

---

## Hand-rolled SQLite layer (direct C API / SQLiteNIO-style)

"Write it yourself" splits into two quite different propositions, and they should not be assessed as one:

- **(a) Direct C API.** `import SQLite3` against the system library — no package dependency at all. The module is real and shipping: `usr/include/module.modulemap` in the macOS 26.5 SDK contains `extern module SQLite3 "SQLite3.modulemap"`, alongside `usr/include/sqlite3.h` (verified directly in `/Applications/Xcode.app/.../MacOSX26.5.sdk` on the survey machine, Xcode 26.6 / 17F113). Same in `iPhoneOS26.5.sdk`.
- **(b) SQLiteNIO-style.** Take a thin third-party C wrapper instead of writing one. The named example, [`vapor/sqlite-nio`](https://github.com/vapor/sqlite-nio), is **not** in the same category as GRDB — see below.

### Maturity on latest released OS

**The engine is the mature part; the layer is not.** SQLite itself needs no defence ([sqlite.org/mostdeployed.html](https://www.sqlite.org/mostdeployed.html)). What a hand-rolled layer has zero maturity in is the several thousand lines of statement caching, transaction helpers, error mapping, busy handling, row decoding, migration bookkeeping and change observation that GRDB has been accreting since 2015.

**What Apple actually ships, measured rather than assumed** (all from the survey machine, macOS Tahoe 26.6.2 / Xcode 26.6):

| Fact | Value | How obtained |
| --- | --- | --- |
| SDK header version | `#define SQLITE_VERSION "3.51.0"` | `iPhoneOS26.5.sdk/usr/include/sqlite3.h` |
| Runtime library | `3.51.0 2025-06-12 … apl` | `/usr/bin/sqlite3 --version` (Apple build of the same `libsqlite3`) |
| Upstream current | **3.53.4, 2026-07-24** | [sqlite.org/chronology.html](https://www.sqlite.org/chronology.html) |
| Threading mode | **`THREADSAFE=2`** | `PRAGMA compile_options` |
| FTS5 | `ENABLE_FTS5` present (also FTS3/FTS4, RTREE, `ENABLE_SESSION`, `ENABLE_PREUPDATE_HOOK`, `ENABLE_SNAPSHOT`, math functions) | `PRAGMA compile_options` |
| Loadable extensions | **`OMIT_LOAD_EXTENSION`** | `PRAGMA compile_options` |
| Durability defaults | `DEFAULT_SYNCHRONOUS=2` (FULL), `DEFAULT_WAL_SYNCHRONOUS=1` (NORMAL), `DEFAULT_CKPTFULLFSYNC` | `PRAGMA compile_options` |

Three consequences fall straight out of that table:

1. **The system SQLite is roughly 14 months behind upstream** and Apple publishes no compatibility statement about which SQLite version ships in which OS — there is no `developer.apple.com` page documenting it; developers discover it by reading the SDK header or by hitting a missing feature and then vendoring their own amalgamation, which is exactly the shape of [Apple forum thread 756186](https://developer.apple.com/forums/thread/756186). **Confidence: high** on the measured versions (direct observation); **high** that Apple does not document the mapping (no such page exists); **medium** on generalising the 14-month lag to future releases — it is one data point, not a stated policy.
2. **`OMIT_LOAD_EXTENSION` means the system library cannot load extensions at runtime.** Anything not compiled in (a custom tokenizer as a loadable module, vector search, `sqlite-vec`) requires vendoring your own SQLite build. FTS5 *is* compiled in, so the search story is fine, but the escape hatch is closed.
3. **`THREADSAFE=2` is multi-thread mode, not serialized** — see the next section. This is the single most under-appreciated fact about hand-rolling on Apple platforms.

On **SQLiteNIO** specifically: 1.13.0 (2026-07-28), MIT, Swift 6.1+, macOS 10.15+ / iOS 13+, **78 stars, 2 open issues** ([GitHub API](https://api.github.com/repos/vapor/sqlite-nio)). Since 1.12.x it **vendors the SQLite amalgamation** rather than linking the system library — 1.12.10 embeds 3.53.4 ([releases](https://github.com/vapor/sqlite-nio/releases)) — which solves the version-lag and `OMIT_LOAD_EXTENSION` problems at the cost of shipping the engine in your binary. But it is a *SwiftNIO* client: its concurrency model is event loops and a `NIOThreadPool` onto which blocking SQLite calls are offloaded, because it exists to back FluentKit on the server. Adopting it in a macOS/iOS app means pulling SwiftNIO into a GUI process to talk to a local file. It is not a peer of GRDB for this use case; it is a server-side building block. **Do not read the SQLiteNIO option as "GRDB but Vapor-flavoured."**

### Concurrency / Sendable — the load-bearing section

This is where hand-rolling collides hardest with the Swift 6 hard gate.

**`sqlite3 *` and `sqlite3_stmt *` import into Swift as `OpaquePointer`, and `OpaquePointer` is explicitly *not* `Sendable`.** [SE-0331 "Remove Sendable conformance from unsafe pointer types"](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0331-remove-sendable-from-unsafepointer.md) (Implemented, Swift 5.6) removed it from `OpaquePointer`, `CVaListPointer`, `AutoreleasingUnsafeMutablePointer` and the whole `Unsafe*Pointer` family. The stdlib encodes this as an explicitly unavailable conformance — `@available(*, unavailable) extension UnsafePointer: Sendable where Pointee: ~Copyable {}` ([`UnsafePointer.swift`, release/6.3](https://github.com/swiftlang/swift/blob/release/6.3/stdlib/public/core/UnsafePointer.swift)). The proposal's own motivation is precisely the case at hand:

> The `FileHandle` type will be inferred to be `Sendable` because all of its instance storage is `Sendable`. … Removing the conformance of the unsafe pointer types to `Sendable` eliminates the potential for it to propagate out to otherwise-safe wrappers.

Substitute `Database` for `FileHandle`. The practical effect under Swift 6 strict concurrency: **a `struct Connection { let handle: OpaquePointer }` does not become `Sendable` for free, and cannot be made `Sendable` honestly.** You have exactly two routes:

- **Actor confinement.** `actor Database { private let handle: OpaquePointer }` — the handle never escapes, every access is `await`-ed. This is correct and idiomatic, and it is the same shape as a `@ModelActor` or a GRDB `DatabaseQueue`. The cost is that every C call is now behind an actor hop that you designed, and that you must ensure no `sqlite3_stmt` pointer, row pointer or `sqlite3_column_text` buffer ever leaks out of the actor — the compiler will not catch a `String(cString:)` you forgot to materialise inside the isolation domain, because by then it is a `String`.
- **`@unchecked Sendable`.** Assert safety, hand-audit it forever. This is the route most hand-rolled layers take, and it is worth being blunt about what it means: the Swift 6 gate is *satisfied by annotation, not by proof*. Every subsequent contributor is trusted to preserve an invariant the compiler has been told to stop checking.

**And SQLite's own mutexes will not rescue you on Apple platforms.** SQLite's default compile-time setting is serialized mode, where "API calls to affect or use any SQLite database connection or any object derived from such a database connection can be made safely from multiple threads" ([sqlite.org/threadsafe.html](https://www.sqlite.org/threadsafe.html)). **Apple does not ship that default** — the measured `THREADSAFE=2` is *multi-thread* mode, whose contract is materially weaker:

> SQLite can be safely used by multiple threads provided that no single database connection nor any object derived from database connection, such as a prepared statement, is used in two or more threads at the same time. — [sqlite.org/threadsafe.html](https://www.sqlite.org/threadsafe.html)

Serialized mode is still reachable per-connection by passing `SQLITE_OPEN_FULLMUTEX` to `sqlite3_open_v2()` (compile-time 2 permits raising to serialized at open time; only compile-time 0 forecloses it) ([threadsafe.html](https://www.sqlite.org/threadsafe.html)). But note that `sqlite3_threadsafe()` "does not reflect changes to the threading mode made at runtime via the `sqlite3_config()` interface or by flags given as the third argument to `sqlite3_open_v2()`" — so the obvious runtime self-check does not tell you what you actually got. **Confidence: high** — this is compile-option output from the shipping library plus the vendor's own documentation. It is a fact a hand-rolled layer must encode deliberately; it is a fact GRDB already encodes for you.

Other concurrency machinery you inherit responsibility for, each of which GRDB documents as solved:

- **WAL.** `journal_mode=WAL` gives "readers do not block writers and a writer does not block readers", is persistent across connections once set, still allows "only one writer at a time", and "does not work over a network filesystem" ([sqlite.org/wal.html](https://www.sqlite.org/wal.html)). Setting it, checkpointing it, and choosing `synchronous=NORMAL` vs `FULL` under WAL are your calls.
- **`SQLITE_BUSY` handling.** With more than one connection you own the busy-timeout / retry policy.
- **Task cancellation.** There is no free equivalent of GRDB's documented "a cancelled `Task` makes the write throw `CancellationError` and rolls back". The primitive is `sqlite3_interrupt()`, which is safe to call from another thread, returns `SQLITE_INTERRUPT`, and rolls back an interrupted INSERT/UPDATE/DELETE inside an explicit transaction — but "if an SQL operation is very nearly finished … it might not have an opportunity to be interrupted", and "it is not safe to call this routine with a database connection that is closed or might close before `sqlite3_interrupt()` returns" ([sqlite.org/c3ref/interrupt.html](https://www.sqlite.org/c3ref/interrupt.html)). Wiring that to `withTaskCancellationHandler` without a use-after-close race is a genuine piece of engineering, not a line of glue.

### Relational querying

Identical ceiling to GRDB, because it is literally the same engine: recursive CTEs ([sqlite.org/lang_with.html](https://www.sqlite.org/lang_with.html)), partial indexes ([sqlite.org/partialindex.html](https://www.sqlite.org/partialindex.html)), window functions, JSON functions, and FTS5 (confirmed compiled into Apple's build above). Nothing this project needs is out of reach.

The difference is entirely in what sits above the engine:

- **No type mapping.** Every read is `sqlite3_column_int64` / `sqlite3_column_text` at a positional index, with the column order in the `SELECT` and the index in the Swift code kept in agreement by hand. GRDB's runtime-decoding failure mode (a renamed column becomes a decode error) exists here too, but *one level lower* — a mismatched positional index is not an error at all, it is a silently wrong value of the right type. That is a strictly worse failure surface than either GRDB or SwiftData.
- **No query builder**, so dynamic filtering (the Issues list with optional project/status/assignee/label filters) is string concatenation plus manual `sqlite3_bind_*` placeholder bookkeeping — the classic site for both injection bugs and off-by-one bind indexes.
- **No change observation.** The C primitives are `sqlite3_update_hook` / `sqlite3_commit_hook` / `sqlite3_preupdate_hook` (the latter is compiled in, per the table). They are per-connection and report table name plus **rowid**, not the changed values, and they fire inside the write — turning that into a debounced, coalesced, cross-connection `AsyncSequence` suitable for driving SwiftUI is the bulk of what `ValueObservation` is.

### Fit against the locked offline requirements

Because the engine is the same, every ADR 0003/0004 requirement resolves the same way it does under GRDB, and the assessment collapses to "who writes it":

- **Topologically ordered pending-op log.** Recursive CTE over an edge table. Available; you write the SQL either way. No difference from GRDB.
- **Quarantine without head-of-line blocking.** `state` column plus a partial index. Available; no difference from GRDB.
- **Atomic "apply optimistically + enqueue operation".** This is where the difference bites. GRDB's `write { }` closure *is* the transaction, with rollback on throw as a documented framework guarantee. Hand-rolled, `BEGIN`/`COMMIT`/`ROLLBACK` is your `defer` block, your error paths, and your rule about not nesting. Getting this wrong does not produce a crash; it produces a local mutation with no queued operation, or a queued operation with no local mutation — a silent divergence between device and server that surfaces days later. Given ADR 0004's whole premise is that writes are never silently dropped, this is the requirement most sensitive to the choice.
- **Per-field timestamps; indefinitely-retained tombstones.** Plain columns. No difference from GRDB.
- **Durability.** [How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html) is, read from this angle, a checklist of things a storage layer must get right: continuing to use a closed file descriptor (§1.1), backup/restore while a transaction is active (§1.2), deleting a hot journal (§1.3), mispairing database files and hot journals (§1.4), carrying an open connection across `fork()` (§2.7), and disabling sync via PRAGMA (§3.2). Apple's build already defaults to `synchronous=FULL` with `CKPTFULLFSYNC`, so the defaults are safe; the risk is a hand-rolled layer changing them for a benchmark.
- **iOS Data Protection.** On iOS the database file's protection class must be chosen deliberately: the default since iOS 7 is `NSFileProtectionCompleteUntilFirstUserAuthentication`, and under stricter classes the encryption key is dropped when protected data becomes unavailable, so reads and writes fail while the device is locked ([FileProtectionType.complete](https://developer.apple.com/documentation/foundation/fileprotectiontype/complete); DTS discussion in [forum thread 100101](https://developer.apple.com/forums/thread/100101)). This applies to *every* option here — a background sync engine that writes while the device is locked has to care regardless — but a hand-rolled layer has no library default to inherit.

### Migration / schema evolution

`PRAGMA user_version` is the standard hook: a free 32-bit integer in the database header that SQLite itself never uses ([sqlite.org/pragma.html#pragma_user_version](https://www.sqlite.org/pragma.html#pragma_user_version)). A hand-rolled migrator is a switch over it inside a transaction. That is genuinely a small amount of code — perhaps 60 lines — and it is the part of hand-rolling that is *not* a bad trade. What you don't get for free: per-migration transactions with rollback, deferred foreign-key checks during migration, migrate-up-to-N for tests, and "database is newer than this binary" detection, all of which `DatabaseMigrator` provides.

You also inherit SQLite's `ALTER TABLE` limits directly, with no helper wrapping the create-new-table-and-copy recipe ([sqlite.org/lang_altertable.html](https://www.sqlite.org/lang_altertable.html)).

### Notable limitations

- **The Swift 6 gate is passed by assertion, not by proof.** Actor confinement is real isolation; `@unchecked Sendable` around an `OpaquePointer` is a promise. Either is achievable, but neither is *checked*, which is a different quality of compliance from GRDB's "the compiler enforces `Sendable` at the `read`/`write` closure boundary".
- **Positional column decoding fails silently**, unlike GRDB's named decoding or SwiftData's typed properties.
- **You are re-implementing a maintained library.** No requirement in ADR 0003 or 0004 was found that GRDB cannot serve; the case for hand-rolling therefore rests on dependency avoidance and bus-factor arguments, not on capability.
- **SQLiteNIO is not a shortcut to this.** It removes the C-pointer work but replaces it with a SwiftNIO event-loop dependency designed for servers, and a 78-star repo is a *worse* bus-factor bet than GRDB's, not a better one.
- **System-library version lag and `OMIT_LOAD_EXTENSION`** cap what the no-dependency route can ever do; escaping them means vendoring an amalgamation, at which point "no dependency" is no longer the benefit being bought.

---

## Brief assessments: two options that came up and were not shortlisted

### Core Data used directly

Core Data is still shipping, still supported, and still the engine SwiftData is built on — so "SwiftData is a Core Data stack" already means this project gets Core Data's durability and query planner whichever of the two it picks. The question is whether to skip the wrapper and use `NSPersistentContainer` / `NSManagedObjectContext` directly.

**The signal that matters most is where Apple's documentation effort goes.** Apple's [framework updates index](https://developer.apple.com/documentation/updates) lists **81 `… updates` pages** — AppKit, Foundation, SwiftUI, Swift Charts, Core Location, Core ML, Core Motion, Core Spotlight, and **SwiftData**. There is **no "Core Data updates" page.** The only Core Data item reachable from that index is [Adopting SwiftData for a Core Data app](https://developer.apple.com/documentation/coredata/adopting-swiftdata-for-a-core-data-app). Read that for exactly what it is: Core Data is maintained, not developed, and Apple's documented migration arrow points one way. **Confidence: high** on the observation (queried directly from the docs index JSON); **medium** on the inference — absence of an updates page is strong but circumstantial evidence, not a deprecation.

**Its Swift 6 story is better than its reputation, and worse than it looks.** The widely repeated forum claim that `NSManagedObjectContext` is non-`Sendable` is **out of date**. In the shipping macOS 26.5 SDK the header reads:

```objc
NS_SWIFT_NONISOLATED NS_SWIFT_SENDABLE
@interface NSManagedObjectContext : NSObject <NSCoding, NSLocking>
```

(`CoreData.framework/Headers/NSManagedObjectContext.h:84`, verified on the survey machine; Apple's docs conformance list agrees — [NSManagedObjectContext](https://developer.apple.com/documentation/coredata/nsmanagedobjectcontext) conforms to `Sendable`, as do [NSPersistentContainer](https://developer.apple.com/documentation/coredata/nspersistentcontainer) and [NSPersistentStoreCoordinator](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator)). `NSManagedObject` itself is **not** `Sendable`; `NSManagedObjectID` **is**.

That is a *worse* compile-time story than SwiftData's, not a better one. SwiftData's `ModelContext` is deliberately non-`Sendable`, so the compiler stops you moving a context across an isolation boundary. Core Data's context is annotated `Sendable` and `nonisolated`, so the compiler *lets you*, and the actual thread-confinement rule — every access inside `perform`/`performAndWait` on the context's own queue — is enforced by nothing but discipline. Swift 6 mode will compile code that Core Data considers undefined behaviour. Forum traffic on the resulting confusion is heavy ([Apple forum 756807 "Using Core Data with the Swift 6 language mode"](https://developer.apple.com/forums/thread/756807), [forums.swift.org "Using Core Data context.perform with Swift 6 & Concurrency"](https://forums.swift.org/t/using-core-data-context-perform-with-swift-6-concurrency/74578), [forums.swift.org "CoreData, Concurrency, and Background Context Confusion"](https://forums.swift.org/t/coredata-concurrency-and-background-context-confusion/79030)). **Confidence: high** on the annotations (SDK header + docs); **high** that the annotation does not change Core Data's underlying queue-confinement contract.

**Verdict for this ticket: it does not deserve a shortlist slot.** Against SwiftData it costs a large amount of Objective-C-era ceremony (`.xcdatamodeld`, generated `NSManagedObject` subclasses, `NSFetchRequest` and `NSPredicate` without type safety) and buys back things this project does not need — `NSFetchedResultsController`, fine-grained store configuration, `NSBatchUpdateRequest`. Against GRDB it loses on every axis that matters here: no raw SQL, no recursive CTEs for the topological queue walk, no partial indexes, no FTS5. The one scenario that would revive it is a decision to use SwiftData *and* discover a specific capability gap, since the two can share a store — but that is a fallback within the SwiftData branch, not a third option.

### SQLite.swift (`stephencelis/SQLite.swift`)

The obvious "other GRDB". At survey time: MIT, **10,189 stars**, **143 open issues**, last push 2026-08-29, latest release **0.16.0 (2026-03-08)** ([GitHub API](https://api.github.com/repos/stephencelis/SQLite.swift), [CHANGELOG](https://github.com/stephencelis/SQLite.swift/blob/master/CHANGELOG.md)). It is popular, alive, and offers a genuinely pleasant type-safe expression builder over SQLite.

**It is nevertheless disqualified by the Swift 6 hard gate, on the project's own evidence.** Its `Package.swift` declares:

```swift
swiftLanguageModes: [.v5],
```

([Package.swift](https://github.com/stephencelis/SQLite.swift/blob/master/Package.swift)). The library does not build in Swift 6 language mode; it builds in Swift 5 mode with `swift-tools-version: 6.1`. Sendability arrived only in **0.15.5 (2026-01-22)** — "Added sendability conformance (#1332)" — roughly **four years** after `Sendable` shipped and a year after GRDB 7 made it the headline of a major version. The tracking issue [#1266 "Will this lib consider `sendable`?"](https://github.com/stephencelis/SQLite.swift/issues/1266), opened 2024-04-25, is still open.

Consuming a `.v5`-mode package from a Swift 6 app is legal — the mode is per-module — but it means the library's own types carry Swift-5-era Sendable inference, and every point where one of them crosses an isolation boundary in your code is your problem to prove, with no upstream guarantee that the proof stays valid. Compare GRDB, which ships a DocC article specifically on Swift concurrency and enumerates its own strict-concurrency papercuts with fixes.

Secondary marks against: still **0.x after eleven years**, so no semantic-versioning promise; 143 open issues against GRDB's 7; no first-class change-observation story comparable to `ValueObservation`; and no migration framework comparable to `DatabaseMigrator` (schema changes go through a `SchemaChanger` helper). **Verdict: not a shortlist candidate** — it is strictly dominated by GRDB on every criterion this ticket asks about, and it fails the one criterion that is a hard gate.

---

## Apple sync layers — status, and why they are out of scope

There are two Apple-supplied sync layers on the latest released OS, and a third thing that is not a sync layer at all. All three sync **to CloudKit**. This project syncs to its **own HTTP server** (ADRs 0003/0004), so none of them can be adopted — but two of them are worth reading, for different reasons.

### 1. `NSPersistentCloudKitContainer` / SwiftData's `cloudKitDatabase:` — the high-level mirror

Status: shipping and supported. SwiftData exposes it through `ModelConfiguration(cloudKitDatabase:)`, disabled with `.none` ([Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)); Core Data exposes it through `NSPersistentCloudKitContainer` ([Mirroring a Core Data store with CloudKit](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit)).

**Not adoptable here for a structural reason, not a preference one.** Apple's own words:

> Apps using CloudKit cannot use Core Data with CloudKit with existing CloudKit containers. To fully manage all aspects of data mirroring, **Core Data owns the CloudKit schema created from the Core Data model.** — [Mirroring a Core Data store with CloudKit](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit)

The mirror is a closed loop between a Core Data model and a CloudKit container whose schema Core Data generates. There is no seam at which a third-party HTTP API could be substituted for the CloudKit side. It is not "a sync engine you point at a server"; it is "CloudKit, driven from your model".

**Its constraints are still instructive**, because they are Apple's own answer to "what must a data model give up to be reconcilable by a generic server?":

- "CloudKit does not support **unique constraints**, undefined attributes, or **required relationships**" ([Mirroring a Core Data store with CloudKit](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit)) — the SwiftData page adds that the `.deny` delete rule is unsupported.
- Schema is **immutable once promoted to production**: "the record types and their fields are immutable and exist for all time. You can add new record types, and additional fields to existing record types, but you can't modify or delete existing record types" ([Creating a Core Data model for CloudKit](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit)).

Compare that to what this project has locked in. ADR 0003 requires client-generated UUIDv7 primary keys, deterministic UUIDv5 label ids, per-field timestamps on six scalars, and indefinitely-retained tombstones; ADR 0004 requires a topologically ordered replay with per-record quarantine. **None of that is expressible through the mirror** — it has no notion of a per-field clock, no notion of quarantine, and its conflict resolution is not yours to define. The mirror is a *backup-and-distribute* feature; this project needs an *arbitrated multi-writer merge*. Even a project that wanted CloudKit would have to leave the mirror to get ADR 0003's semantics.

Correct configuration for this project, on either framework, is therefore explicit: `cloudKitDatabase: .none` on SwiftData, or plain `NSPersistentContainer` on Core Data. **This is not a differentiator between the storage options** — every option in this survey requires the full ADR 0003/0004 sync engine to be hand-written.

### 2. `CKSyncEngine` — the low-level engine, and the best available reference architecture

Status: shipping since **iOS 17.0 / iPadOS 17.0 / macOS 14.0 / tvOS 17.0 / watchOS 10.0 / visionOS 1.0** ([CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9)). Still CloudKit-only — `init(configuration:)` takes a `CKDatabase`, and "Don't use `CKSyncEngine` to sync your app's public database."

It is out of scope for adoption for the same reason as the mirror. But it is **worth reading before designing the queue in ticket 05**, because it is Apple's considered answer to the same problem and it independently arrives at several of ADR 0004's conclusions:

- **The app owns a durable pending-change log, not the engine.** "A sync engine requires you to tell it about any changes to send, which you do by invoking the `addPendingDatabaseChanges:` and `addPendingRecordZoneChanges:` methods on the engine's `state` property." Even Apple's sync engine does not discover your changes for you.
- **The app persists the engine's state.** "The sync engine uses an opaque type to track its internal state, and **it's your responsibility to persist that state to disk** and make it available across app launches so the engine can function properly." That state lives *somewhere* — which in this project means a table in whichever store wins, and is one more reason the storage layer and the queue want to be in the same transaction.
- **Sending is explicitly batched, with the app choosing each batch.** "the engine drives a send operation by repeatedly invoking `syncEngine:nextRecordZoneChangeBatchForContext:` to gather those changes into batches and sending each batch as one request. It keeps asking for batches until your delegate returns `nil`." That delegate callback is structurally the same hook as ADR 0004's "next topologically sendable batch, skipping the quarantined closure" query.
- **Scheduling is indeterminate; immediate sync is a separate explicit call.** "the engine's sync schedule is indeterminate… If you need to sync immediately… use `fetchChangesWithOptions:completionHandler:` and `sendChangesWithOptions:completionHandler:`."

What `CKSyncEngine` does **not** give, and what this project must therefore build regardless: topological ordering across records (CloudKit's unit is the record zone, and the engine has no notion of "parent before child"), per-operation quarantine with an error payload surfaced to the user, and per-field last-write-wins arbitration.

### 3. Persistent history tracking — not a sync layer, but the piece people mistake for one

Core Data's persistent history and SwiftData's `fetchHistory(_:)` / `HistoryProviding` (iOS 18+, with `HistoryObserver` arriving in the still-beta OS 27 wave — see the SwiftData section) give a durable, ordered transaction log of local store changes. It is tempting to read that as "the pending-operation queue, for free." It is not:

- It records **what changed in the store**, not **what intent to send to the server**. ADR 0004's queue entries carry a server-rejection error, a quarantine state, and a causal parent — none of which is a store mutation.
- It has no dependency edges, so no topological replay.
- Its retention is a purge-token protocol designed for multiple in-process consumers, not indefinite retention of unsent work.

It is genuinely useful as the *change-detection* half of a sync engine (a cheap way to know which rows to consider), and that is how it should be evaluated in ticket 05 — as an optimisation available on the SwiftData/Core Data branch, not as a substitute for the queue.

---

## Comparison

Shortlisted options in the first three columns; the two assessed-and-dropped options in the last two, kept in the table so the decision in ticket 05 can show its working.

| | **SwiftData** | **GRDB** | **Hand-rolled SQLite** (direct C API) | Core Data direct | SQLite.swift |
| --- | --- | --- | --- | --- | --- |
| **Nature** | Apple framework, in-OS | MIT package | No dependency (system `SQLite3` module) | Apple framework, in-OS | MIT package |
| **Version at survey** | iOS 26 / macOS 26 (OS 27 wave in beta) | **7.11.1**, 2026-06-18 | System SQLite **3.51.0**; upstream 3.53.4 | iOS 26 / macOS 26 | **0.16.0**, 2026-03-08 |
| **Engine** | Core Data → SQLite | SQLite | SQLite | SQLite | SQLite |
| **Age / track record** | 3 years | 11 years, 7 open issues | Engine ancient, *your layer* is new | ~20 years, maintenance mode | 11 years, still 0.x, 143 open issues |
| **Swift 6 strict concurrency** | Passes — `ModelContext` deliberately **non-`Sendable`**, `@ModelActor` is the sanctioned shape | Passes — **compiler-enforced** at the `read`/`write` closure boundary; dedicated DocC article | Passes **by assertion** — `OpaquePointer` is non-`Sendable` (SE-0331), so actor confinement or `@unchecked Sendable` | Compiles, but `NSManagedObjectContext` is annotated `NS_SWIFT_SENDABLE` + `NS_SWIFT_NONISOLATED`, so the checker **cannot** enforce queue confinement | **Package is `swiftLanguageModes: [.v5]`** |
| **Concurrency primitive** | `@ModelActor` (framework-owned executor) | `DatabaseQueue` / `DatabasePool` (WAL), held by *your* actor | Whatever you build; note Apple ships `THREADSAFE=2` (**multi-thread**, not serialized) | `context.perform` on a private queue | Connection-level, undocumented guarantees |
| **`Task` cancellation** | Not documented | **Documented**: cancelled task → `CancellationError`, transaction rolled back | `sqlite3_interrupt()` + your own `withTaskCancellationHandler`, with a use-after-close hazard | Not documented | Not documented |
| **Raw SQL escape hatch** | **None** — on-disk format is a private implementation detail | Unrestricted, with SQL-interpolation injection safety | Unrestricted | None | Unrestricted |
| **Recursive CTE** (topological replay) | ✗ — walk the graph in Swift, or denormalise | ✓ | ✓ | ✗ | ✓ |
| **Partial index** (quarantine without head-of-line blocking) | ✗ — `#Index` only | ✓ | ✓ | ✗ | ✓ |
| **Full-text search** | ✗ — `contains` scan only, no path to FTS5 | ✓ FTS3/4/5, external content, ranking | ✓ FTS5 confirmed compiled into Apple's `libsqlite3` | ✗ | ✓ (behind a package trait) |
| **Atomic "mutate locally + enqueue op"** | `transaction(block:)` with `autosaveEnabled = false` — a convention you maintain | `try await writer.write { }` **is** the transaction; rollback on throw is a framework guarantee | Your own `BEGIN`/`COMMIT`/`ROLLBACK` and `defer` | `perform` + `save()` | Manual `transaction` block |
| **Per-field timestamps (6 Issue scalars)** | 6 attributes; no per-property change hook | 6 columns or a JSON column | 6 columns | 6 attributes | 6 columns |
| **Indefinite tombstones** | `deletedAt` column; means never calling `delete(_:)`, so delete rules go unused — against the grain | `deleted_at` + partial index or a view (`ViewRecords`) | `deleted_at` + partial index | Same friction as SwiftData | `deleted_at` column |
| **Change observation → UI** | `@Query` in SwiftUI; **outside SwiftUI, `ResultsObserver`/`HistoryObserver` are OS 27 only** — on 26 it's `willSave`/`didSave` + history polling | `ValueObservation.values(in:)` `AsyncSequence`; SwiftUI wrapper is **GRDBQuery 0.11.0, unpushed since 2025-03** | `sqlite3_update_hook`/`commit_hook` — rowids only, no coalescing; you build the rest | `NSFetchedResultsController`, persistent history | No first-class equivalent |
| **Migrations** | `VersionedSchema` + `SchemaMigrationPlan`; every historical schema stays in the binary | `DatabaseMigrator`: named, ordered, per-migration transaction, `migrate(upTo:)`, merged migrations | `PRAGMA user_version` switch (~60 lines) | `.xcdatamodeld` versions + mapping models | `SchemaChanger` helper |
| **Schema-drift failure mode** | Runtime `unsupportedPredicate` at fetch; predicate subset undocumented | Runtime **decode error** on a renamed column — loud | **Silently wrong value** on a positional-index mismatch — quiet | Runtime `NSPredicate` failure | Runtime decode error |
| **In-memory store for tests** | `ModelConfiguration(isStoredInMemoryOnly:)` | `DatabaseQueue()` in-memory + `migrate(upTo:)` | `:memory:` | `NSInMemoryStoreType` | `Connection(.inMemory)` |
| **Governance / bus factor** | Apple — no bus factor, but **unforkable**; you cannot fix the predicate subset | One dominant maintainer (`@groue`), MIT, forkable | You are the maintainer | Apple, maintenance mode | Community, 143 open issues |
| **Runs off Apple platforms** (shared Core package, CLI/MCP) | ✗ | ✓ (Linux/Android/Windows since 7.10.0) | ✓ (link any SQLite) | ✗ | ✓ |
| **CloudKit mirror available** | ✓ (`cloudKitDatabase:`) — **irrelevant here, set `.none`** | ✗ | ✗ | ✓ — irrelevant here | ✗ |
| **Shortlisted for ticket 05?** | Yes | Yes | Yes | **No** | **No** |

Verified directly on the survey machine (macOS Tahoe 26.6.2, Xcode 26.6 / 17F113) rather than from documentation: system SQLite version, `THREADSAFE=2`, `ENABLE_FTS5`, `OMIT_LOAD_EXTENSION`, and the `NS_SWIFT_SENDABLE` annotation on `NSManagedObjectContext`.

---

## Considerations for the decision

Input to [ticket 05](../issues/05-choose-local-storage-offline-queue.md). **No recommendation is made here.** These are the axes on which the three shortlisted options actually differ, ordered by how much they should move the decision.

### 1. Where the topological-ordering invariant lives

ADR 0004 states the queue is "a topologically ordered log, not merely a chronological one" and calls this "a hard requirement on the queue design in ticket 05". It is also the single largest capability gap in the table.

On SQLite (GRDB or hand-rolled) the ordering and the "quarantine the transitive closure of a failed op" rule are both recursive CTEs — declarative, testable in isolation with a SQL fixture, and evaluated by the engine. On SwiftData they are Swift code over fetched rows, or denormalised columns you maintain on every write, with no ordered-relationship guarantee to lean on. Neither is disqualifying. The question ticket 05 should answer explicitly is **whether the correctness of the replay order should be an engine property or an application property**, because that choice is very hard to reverse later — it is the shape of the queue, not an implementation detail of it.

### 2. Deployment target: 26 vs 27, which changes SwiftData's score and nothing else's

OS 27 is at beta 8 and ships within weeks. SwiftData's non-SwiftUI observation API (`ResultsObserver`, `HistoryObserver`) is **27-only**. This project's sync engine writes on a background actor and must refresh the UI — precisely the case those APIs address.

So SwiftData's comparative weakness on change observation is **temporary and schedule-dependent**, and GRDB's and hand-rolled's positions are unaffected by the same decision. Ticket 05 should not evaluate SwiftData without first fixing the minimum deployment target; the two decisions are coupled. If the answer is "26 for the first release", SwiftData's background-write→UI-refresh path is `willSave`/`didSave` notifications plus history polling for the lifetime of that release.

### 3. What quality of Swift 6 compliance the hard gate actually demands

All three shortlisted options ship on Swift 6 with full strict concurrency. They do not pass it the same way:

- **GRDB**: the compiler enforces `Sendable` at every `read`/`write` closure boundary. Violations are build errors.
- **SwiftData**: `ModelContext` is deliberately non-`Sendable`, so the compiler stops you moving a context across isolation domains; the residual discipline is "don't let a `PersistentModel` escape the `ModelActor`", which the compiler *also* enforces.
- **Hand-rolled**: `OpaquePointer` is non-`Sendable` per SE-0331, so you either confine it to an actor (real isolation, but the compiler cannot see that a `sqlite3_column_text` buffer escaped) or write `@unchecked Sendable` (the gate is satisfied by annotation).

If "Swift 6 strict concurrency" is meant as *"the compiler proves our data-race safety"*, hand-rolling is the weakest of the three and should be scored accordingly. If it is meant as *"the project builds cleanly in Swift 6 language mode"*, all three tie. Ticket 05 should state which reading it is using, because this is a stated hard gate and the three options are not equivalent under the stricter reading.

### 4. The atomicity invariant is the one most expensive to get wrong

"Apply the optimistic local mutation **and** append the pending operation, or do neither" is the invariant that ADR 0004's no-silent-drops guarantee rests on. Losing it does not crash; it produces a device whose local state and server state have quietly diverged, discovered days later by a user.

All three can hold it. They differ in who is accountable: GRDB's `write { }` closure *is* the transaction with documented rollback-on-throw; SwiftData's `transaction(block:)` with `autosaveEnabled = false` is a convention you must apply at every call site; hand-rolled it is your own `defer`. Weight this against how many places in the codebase will perform a local write.

### 5. Asymmetric cost of the search ceiling

The v1 floor asks only for basic search, which SwiftData reaches with a `contains` predicate scan. But SwiftData has **no raw-SQL escape hatch at all** — the on-disk format is a private Core Data implementation detail — so if search later needs FTS5, ranking, or a hand-written query the planner needs help with, the remedy is *changing storage layers*, not adding an index. GRDB and hand-rolled SQLite carry FTS5 as a schema change (and it is confirmed compiled into Apple's system library).

This is a bet on requirements, not a capability comparison: the cost of choosing SwiftData and being wrong is much higher than the cost of choosing SQLite and never needing FTS5.

### 6. Which risk the project prefers to hold: unforkable vendor, or single maintainer

- SwiftData/Core Data: no bus factor, but **you cannot fix anything**. The undocumented `#Predicate` subset and the unspecified to-many ordering are permanent constraints, and the workaround for a blocking bug is a radar and a wait.
- GRDB: MIT, ~8.6k stars, but nearly every PR is by one maintainer. The mitigation is that the code is small, stable and forkable, and that it is a thin layer over an engine with a 20-year compatibility record.
- Hand-rolled: the bus factor is the team, and the surface is the several thousand lines that GRDB has already debugged.

These are genuinely different risks, not one risk with three magnitudes, and the choice is a judgement about the project rather than about the libraries.

### 7. Velocity in the UI layer is SwiftData's real advantage, and it is not small

`@Query` plus `@Model` plus the SwiftUI environment removes a whole layer. GRDB's equivalent is either **GRDBQuery 0.11.0** — pre-1.0 and not pushed since March 2025 — or roughly a day of writing an `@Observable` wrapper around `ValueObservation.values(in:)`. That wrapper is small, well-understood, and code you own; but it is code that does not exist on day one, and the SwiftData path has no equivalent to write.

Ticket 05 should price this honestly rather than dismissing it, because it is the axis on which SwiftData wins outright.

### 8. Reuse across the shared Core package

If the CLI or MCP surfaces are ever expected to open the same store — or if any part of the shared Core package (ADR 0002) wants to run on Linux in CI — SwiftData and Core Data are Apple-platform-only and end the discussion. GRDB has shipped Linux/Android/Windows support since 7.10.0, and raw SQLite runs anywhere. Establish whether this is a real requirement or a hypothetical one *before* weighing it; it is decisive if real and worthless if not.

### 9. What is explicitly *not* a differentiator

Listing these so ticket 05 does not spend argument on them:

- **CloudKit.** Excluded for all options by ADR 0003/0004; every option is configured with sync off.
- **Hand-writing the sync engine.** Required under every option. No option in this survey supplies replay ordering, quarantine, per-field last-write-wins, or tombstone semantics.
- **Per-field timestamps and tombstones.** Six columns and one column, in every option. Only the ergonomics of "never hard-delete" differ, and only slightly.
- **Durability of SQLite itself.** Identical engine underneath all three shortlisted options; Apple's build already defaults to `synchronous=FULL` with `CKPTFULLFSYNC`.
- **Migrations.** All three have a workable story. They differ in ceremony, not in capability.
