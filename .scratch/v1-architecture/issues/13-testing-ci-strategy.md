# Testing & CI strategy across five surfaces

Type: grilling
Status: resolved

Blocked by: 04, 05, 09

## Question

Define the testing and CI strategy for the monorepo: test framework, what TDD applies to, coverage targets and whether they gate, how the sync engine and the two write paths are tested, and where CI runs given the server is macOS-only. This was flagged as unspecified throughout the architecture effort and is cheaper to settle before implementation than after.

## Settled before grilling

- **TDD is the working mode** for implementation.
- **Aim for the highest practical test coverage.**

## Resolution

No ADR: this is process rather than architecture, and the one decision with architectural reach (the contract test enforcing ADR 0005's anti-drift claim) belongs to that ADR rather than a new one.

### Framework

**Swift Testing** (`@Test`, `#expect`, parameterised cases) — current on Swift 6.3 and consistent with the latest-released-only policy. Parameterised tests suit a domain full of enum permutations and conflict matrices. XCTest only where Swift Testing does not reach: XCUITest smoke tests and performance measurement.

### Coverage

Per-target floors, enforced in CI, **plus a no-regression rule** (coverage may not fall between commits):

| Target | Floor |
| --- | --- |
| Core (domain, validation, `Patchable`, sync logic) | **90%** |
| Server | **80%** |
| CLI / MCP | **70%** |
| Apps — view models | **80%** |
| Apps — view bodies | **no gate** |

A single global percentage was rejected: it is gameable and it pushes people to assert against SwiftUI view bodies to move a number. The no-regression rule does more real work than any absolute figure, because it catches the actual failure mode — a rushed feature landing untested. Exempting view bodies is deliberate; testing that a `VStack` contains a `Text` is theatre.

### CI

**GitHub Actions on `macos-latest`.** Linux containers are unavailable to us — the server is macOS-only (ADR 0010) — so every job needs a Mac runner.

**Cost named up front: on a private repo, macOS minutes bill at 10× the Linux rate.** That is the ADR 0010 decision showing up somewhere concrete, and it is the main reason the suite has a time budget.

**No self-hosted runner on the Mac hosting the Instance** — a second thing to maintain, and CI on the production box invites a suite that wipes a database it should not.

### Where TDD applies

**Test-first**: Core, server, CLI, MCP, and above all the sync engine.

**Not test-first**: SwiftUI view bodies (test view models instead) and database migrations — a migration is verified by running it against a fixture database, and a failing test first for a schema change is ceremony rather than design pressure.

**Held hardest: `Patchable<T>` is written test-first, before anything depends on it.** Absent-vs-null is what ADR 0005 flagged as needing to be right exactly once, and its failure mode is silent field wipes.

### Sync engine — the highest-value testing decision

A **deterministic in-memory harness**: a fake server implementing the push/pull contract over an in-memory store, in-memory GRDB clients, driven by a scripted timeline. Every specified scenario becomes an ordinary fast unit test — quarantine without head-of-line blocking, superseded-by-deletion, echo reconciliation, epoch change forcing a resync, orphan records arriving before their parents.

Plus **property-based convergence testing**: generate random operation orders across N clients and assert identical converged state. That is the bug class this design is most exposed to, and the only realistic way to find it before users do. Manual QA cannot cover "two clients edit different fields offline, one deletes the issue, a third returns after three days".

### Integration, and enforcing ADR 0005's anti-drift claim

One integration layer: **boot the real Hummingbird server on a random port against a temp SQLite file, drive it with the real Core API client.**

And specifically a **contract test asserting REST and sync push produce identical server state for equivalent operations.** [ADR 0005](../../../docs/adr/0005-two-write-paths-one-concurrency-model.md) rests the entire no-drift argument on both paths sharing Core's DTOs — which is a hope until something checks it. This test is that claim in executable form.

### The five sync surfaces

**No image snapshot tests** — brittle across OS versions, and regenerating them burns the expensive Mac minutes above. Three layers instead:

1. **View-model tests** for state correctness (a quarantined op with two dependents reports three needing attention).
2. **One rendering test per state against the shared `SyncStatusView`.**
3. **A single smoke launch per platform**, not one per state.

Layer 2 costs almost nothing **because ticket 10 chose variant C**: `SyncStatusView` exists once, so its five states are tested once and platform compositions merely place it. Under the divergent variant this would have been ten rendering tests across two implementations free to drift. An unplanned second argument for C.

### CLI output

**Exhaustive tests against `--json` and the documented exit codes** — both are contracts.

**Human output tested for properties, never exact strings**: contains the issue key, renders the `PROJ-•` placeholder, says "deleted" rather than "not found" on a 410. Golden-filing the table would quietly make it stable, contradicting ticket 11's explicit statement that it is not — and within a month nobody would dare change the formatting.

### Fixtures

A **`TestSupport` target** with builders for the six entities (`Issue.fixture(status: .done)`), defaults filled and everything overridable. Linked only by test targets, never shipped. Hand-rolled entities per test file drift until two files disagree about what a valid Issue is.

### Time budget

**Unit suite under 60 seconds. Full CI under 10 minutes.**

Not arbitrary — it falls out of two earlier decisions. The pre-commit hook is only viable if Core's tests are fast, and Mac runners bill at 10× on a private repo. Stating the budget now is what keeps the sync harness in-memory rather than drifting toward booting a real server per test.

### Local loop

A **`Makefile`** (`make test`, `make lint`, `make format`) as the one obvious entry point, **swift-format** with a checked-in config, and a **pre-commit hook running format plus Core's unit tests only** — not the full suite. A hook slow enough to be annoying gets bypassed with `--no-verify` within a week, which is worse than not having one.
