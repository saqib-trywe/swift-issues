# CLI command surface & auth flow

Type: grilling
Status: resolved

Blocked by: 01, 06, 07

## Question

Design the CLI's command surface (e.g. `issues project list`, `issues issue create`, `issues issue comment` — actual naming TBD) and output format (human-readable by default, `--json` for scripting), plus how the CLI authenticates given the auth model — a device-code-style flow, or pasting in a pre-issued API token? Builds on the resolved [Domain model v1](../issues/01-domain-model-v1.md), [HTTP API contract design](../issues/06-http-api-contract-design.md), and [Auth model design](../issues/07-auth-model-design.md).

## Inherited constraints (from resolved ticket 06)

- The CLI gets **no special endpoints** — it uses the same REST surface as everything else.
- Issue Key lookup (`GET /api/v1/issues/PROJ-142`) and the `assignee=me` / `assignee=none` tokens exist specifically for CLI and MCP ergonomics; the command surface should lean on them rather than resolving UUIDs first.
- Deleted issues return **410 Gone** as distinct from 404 — worth distinct error copy ("that issue was deleted" vs "no such issue").
- Filtering is flat query params: comma values OR within a parameter, AND across parameters. Flag design should map onto that directly rather than inventing a richer query syntax the API cannot serve.
- The CLI writes through `PATCH` with Merge Patch semantics, so it needs a way to express **clear this field** (send `null`) distinctly from **leave it alone** (omit) — e.g. `--assignee=` versus not passing the flag.

## Inherited constraints (from resolved ticket 07)

- Auth is a **pasted or locally-minted personal access token**, not a device-code flow — there is no web UI to complete one against.
- **`issues auth token create` accepts an interactive email/password login** as the bootstrap path, because a user with no token cannot call an authenticated API to mint one. This is the only place a password crosses the CLI; the command surface should make that boundary obvious.
- PATs carry the same permissions as their owner — no scope flags to design.
- Failed auth is throttled per account (backoff after 5 failures, 15-minute cap), so the CLI needs sane messaging for a lockout rather than a bare 401.

## Resolution

Locked. No ADR: this is ergonomics layered over decisions already recorded in [ADR 0005](../../../docs/adr/0005-two-write-paths-one-concurrency-model.md) and [ADR 0006](../../../docs/adr/0006-auth-model.md).

### Grammar

Binary `issues`, `issues <noun> <verb>` via swift-argument-parser, with **`issue` as the implied default noun** — `issues list`, `issues create`, `issues show PROJ-142`, `issues close PROJ-142`. Other nouns are explicit (`issues project list`). `issues issue list` remains valid as the unambiguous long form. Optimising the commonest command is worth the small irregularity; `issues issue create` stutters on the thing people type most.

### Command surface

| Noun | Verbs |
| --- | --- |
| `auth` | `login`, `logout`, `status`, `token create\|list\|revoke` |
| `issue` (default) | `list`, `show`, `create`, `edit`, `comment`, `assign`, `label`, `close`, `cancel`, `start`, `delete` |
| `project` | `list`, `show`, `create`, `edit`, `archive` |
| `label` | `list`, `create`, `edit`, `delete` (project-scoped) |
| `user` | `list`, `show`, `me`; Admin-only `create`, `deactivate` |
| `config` | `get`, `set` |
| — | `issues completion zsh\|bash\|fish` |

`close`, `cancel`, `start` and `assign` are sugar over `edit` (`close` = `--status done`). Kept deliberately: they are the verbs typed dozens of times a day, and forcing everyone to spell out a status enum for the commonest state change is the kind of purity that gets a CLI abandoned.

**Admin-only commands appear in help for everyone and are rejected at call.** Hiding them would make `--help` depend on server state — requiring a network round trip and a valid token to render help, which then fails offline or in a fresh checkout. Help must work unauthenticated and offline.

### Output

- **Human-readable aligned table by default. `--json` emits the raw API payload verbatim** — not a reshaped CLI schema, which would be a second contract to version and keep in step.
- `--quiet` / `-q` prints bare Issue Keys, one per line, for `xargs`.
- Colour when stdout is a TTY, off otherwise, honouring `NO_COLOR`.
- **Stated in `--help`: the human format is not a stable interface and may change; `--json` is.**

### Config and context

- `~/.config/issues/config.toml` (XDG) — server URL, default project.
- `ISSUES_URL` / `ISSUES_TOKEN` env vars override it; that is the CI path.
- Optional per-directory **`.issues.toml`** holding just a default project key, discovered by walking up from the working directory, so a checkout maps to its Project and `issues create -t "…"` works inside a repo. This is the one convenience worth its complexity — it is the difference between the CLI being used and not.

### Credentials

- **macOS Keychain by default; on Linux a `0600` file** at `~/.config/issues/credentials`. There is no keyring reliable across distros, and pretending otherwise means a broken install on half of them.
- `ISSUES_TOKEN` overrides both and is never written to disk.
- **Tokens stored keyed by server URL**, so pointing at a test instance doesn't clobber real credentials.
- `issues auth login` **stops if a valid session exists**, reporting identity and server; `--force` replaces it. Silently minting a token per invocation produces exactly the sprawl that makes an Admin's revocation list useless.
- `issues auth status` reports identity, server, token kind and expiry — the first thing anyone runs when something is wrong.

### Writes

- **`--unset <field>`, repeatable**, is the single way to clear a field: `issues edit PROJ-142 --unset assignee`. Omitted flag = untouched, `--unset` = null. This is the CLI's expression of Merge Patch's three states.
- **`none` is deliberately not overloaded** for clearing, even though the API uses `assignee=none` as a *filter* token. Reading a filter and writing a clear are different operations, and one word meaning both is how people accidentally unassign things.
- **Markdown input, git-style**: `--description "text"` inline, `--description -` from stdin, **no flag opens `$EDITOR`** with a template. `--no-edit` suppresses it. Same for `issues comment`. If `$EDITOR` is unset and stdin isn't a TTY, fail with a clear message rather than opening `vi` at someone in CI.

### Scripting behaviour

- **Exit codes**: 0 success, 1 generic failure, 2 usage error, 3 not found, 4 auth failure, 5 conflict, 6 gone. Distinguishing 3 from 6 is what makes ticket 06's 410-vs-404 decision reach a user — "that issue was deleted" is a different script branch from "no such issue".
- **Never prompt when stdin isn't a TTY** — fail naming the missing flag, or CI hangs forever on an invisible confirmation.
- **Destructive commands** (`issue delete`, `project archive`, `user deactivate`, `auth token revoke`) prompt on a TTY and require `--yes` otherwise. `issue delete` prompts with the issue's **title**, not just its key — a key alone gives you nothing to notice you have the wrong one, and the tombstone is not undoable from the CLI.
- **Cursors are never exposed.** `--limit N` (default 50) transparently walks pages; `--all` walks everything. Pagination is an API mechanism, not a user concept.
- **Lockout copy**: on 429, render `Retry-After` as "Too many failed attempts — try again in 12 minutes."

### Version skew

The CLI checks `/api/v1/meta` **opportunistically, on `auth login` and `auth status` only**, and warns on **stderr** (keeping `--json` on stdout clean) when the server's API version is newer than it understands. It never blocks. Checking on every invocation would double the latency of a tool whose appeal is being fast, to catch a condition that changes maybe twice a year.

### No offline support

**The CLI is online-only and stateless — no local cache, no replica, no queue.** A cache would be a second sync implementation (replica, tombstones, conflict handling, pending queue) in a surface with none of the UI needed to surface quarantine or superseded edits. Stated cost, which belongs in the CLI's own docs rather than being discovered: `issues list` fails on a plane while the Mac app beside it works fine, and that will look like a bug.
