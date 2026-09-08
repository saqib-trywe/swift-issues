# The server is a single macOS process with an embedded SQLite database

The server is deployed **on macOS only** — no Linux build, no container image, no Linux CI — and stores its data in **SQLite via GRDB**, embedded in the server process rather than in a separate database service. Together these make an Instance one process and one file on one Mac, which is the operational shape a single-team, single-tenant, self-hosted tracker ([ADR 0001](0001-self-hosted-single-tenant-offline-sync.md)) actually needs.

## Considered Options

- **Linux/Docker as the primary target**, which is the conventional answer for self-hosted software and what the map originally assumed. Set aside as a product decision: the deployment target is a Mac.
- **Postgres.** The default assumption for a server database, and rejected for three reasons. First and most technical: ticket 06 specifies the sync pull watermark as an opaque monotonic server sequence, and **with concurrent writers, sequence values can commit out of order** — a client can observe watermark 5 before 4 is visible and skip change 4 permanently. That is silent, unrecoverable data loss that is notoriously hard to reproduce. SQLite in WAL serialises writers so the window cannot open; Postgres requires deliberate work to avoid it. Second, requiring every self-hoster to provision and maintain a database service contradicts the lightweight premise as directly as requiring SMTP did in [ADR 0006](0006-auth-model.md) — more so on macOS, where running Postgres is worse than on Linux. Third, GRDB then serves both client and server, so there is one storage library and one set of migration idioms across the codebase.

## Consequences

- **This narrows who can ever run the software to people with a Mac to spare.** If the project is ever open-sourced or shared beyond this team, that is a hard wall and the most likely reason to revisit this decision. Recorded as a deliberate choice rather than an oversight.
- **macOS server operations are thinner than Linux's**: launchd instead of systemd, no container ecosystem, and a less-trodden path for unattended restarts, log rotation and monitoring. Ticket 09 owns making that concrete.
- **No horizontal scaling, by construction.** Irrelevant under single-tenant, single-box design, but if an Instance ever outgrew one writer, moving to Postgres would be a real project rather than a configuration change.
- **Backup is a first-class command, not a file copy.** See the amendment below — the original claim here was wrong.
- The framework choice in [ADR 0009](0009-hummingbird-and-server-concurrency.md) was **not** influenced by this, which is consistent with the research finding that Linux deployability barely differentiated the candidates.
- The CLI's Linux credential fallback (ticket 11) becomes **incidental rather than required** — harmless to keep, but no longer a supported target unless separately decided.

## Amendment (2026-09-08, from ticket 09)

**Correction — backup is not copying a file.** This ADR originally claimed it was, and pointed at that simplicity as a virtue. It is unsafe: WAL mode (chosen in [ADR 0009](0009-hummingbird-and-server-concurrency.md)'s companion decision to serialise writers) means the database is **three** files, and a live one holds committed data in the `-wal`. Copying them non-atomically, or copying only `issues.sqlite`, yields a corrupt or silently stale backup that appears to work right up until you need it. The supported procedure is **`issues-server backup <path>`**, using SQLite's online backup API to produce a single consistent file with no downtime; naive `cp` of the data directory is explicitly unsupported.

**The server runs as a per-user `LaunchAgent`, not a `LaunchDaemon`**, with every file under `~` (`~/Library/Application Support/Issues/`, `~/Library/Logs/Issues/`, `~/.local/bin/issues-server`). This follows standard macOS per-user convention and makes the whole install rootless — no service account, no admin password, no system-domain package.

The cost, which is the main operational weakness of this design: **a `LaunchAgent` runs only inside a login session.** After a reboot the Instance stays down until someone logs in, and it stops when that user logs out. This must be mitigated at the OS level — automatic login for the account running the server, plus restart-after-power-failure in Energy Saver — and the deployment docs have to say so, because without both an unattended reboot silently takes the Instance offline until a human notices. A `LaunchDaemon` under a dedicated service user avoids this entirely and was the rejected alternative.

**Restore requires an instance epoch in the sync watermark.** Restoring an older backup rewinds the monotonic sequence, so a client holding a high watermark would see empty results forever while silently diverging, with no error anywhere. The watermark is therefore `epoch:seq`, `restore` mints a new epoch, and a stale epoch forces a full resync.
