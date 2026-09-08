# Deployment model for the server

Type: grilling
Status: resolved

Blocked by: 04

## Question

Decide how the server is deployed for self-hosting: distribution format (Docker image? bare binary + systemd unit? both?), supported Linux distros/architectures, configuration mechanism (env vars? config file?), and database provisioning story. Builds on [Choose server framework & concurrency model](../issues/04-choose-server-framework-concurrency-model.md).

## Inherited constraints (from resolved ticket 07)

- The server **assumes TLS is terminated upstream** and refuses to issue or accept tokens over plaintext unless `ISSUES_ALLOW_INSECURE=true`. Deployment docs must cover the reverse proxy, and `X-Forwarded-Proto` is trusted only from configured upstreams.
- **First-run bootstrap**: a one-time token printed to stdout on first start against an empty database (valid 60 minutes), plus `ISSUES_BOOTSTRAP_ADMIN_EMAIL` / `…_PASSWORD` env seeding for scripted deploys. The distribution format must make that stdout line reachable (container logs, journald).
- The server binary must ship **`issues-server admin reset-password`**, runnable on the host — it is the only recovery path for a locked-out sole Admin, since there is no email dependency.
- `GET /health` is unversioned and unauthenticated for liveness probes (ticket 06).

## Inherited constraints (from resolved ticket 12)

- The **MCP executable ships in the same distribution but is not operator-deployed** — it runs as a local stdio process beside the agent, configured by `ISSUES_URL` / `ISSUES_TOKEN`. Packaging must account for a binary the server admin never runs.
- Agent-token rate limiting (60 req/min, burst 120) is server-side behaviour; decide whether it is configurable per Instance or fixed.

## Inherited constraints (from resolved ticket 04)

**This ticket's original question is partly obsolete.** It asks about Docker images, systemd units and supported Linux distros; per [ADR 0010](../../../docs/adr/0010-macos-single-process-server.md) the server is **macOS only** — no Linux build, no container, no Linux CI. Read those parts of the question as superseded.

- **Distribution is a macOS binary**, run under **launchd** rather than systemd. There is no container image to publish.
- **The database is embedded SQLite (GRDB)**, so there is no database service to provision. "Database provisioning" reduces to choosing the data directory and its permissions.
- **Backup is copying the database file.** Document it as the supported procedure — it is easy to get right, which is exactly why it should be written down rather than assumed.
- The **bootstrap token printed to stdout on first run** (ticket 07) needs a defined destination under launchd — unified logging, a log file, or both. This must be reachable by an admin who did not run the binary interactively, or first-run setup is impossible.
- `issues-server admin reset-password` (ticket 07) is the sole lockout recovery path and must be runnable on the host.
- TLS is terminated upstream and the server refuses plaintext tokens unless `ISSUES_ALLOW_INSECURE=true` (ticket 07); `X-Forwarded-Proto` is trusted only from configured upstreams. The reverse-proxy story needs documenting for macOS specifically.
- Open questions this ticket should settle: unattended restart and crash recovery under launchd, log rotation, and how the MCP executable — which ships in the same distribution but is **not** operator-deployed (ticket 12) — is packaged alongside a server binary.

## Resolution

A **rootless, per-user macOS install** under `LaunchAgent`, with an embedded SQLite database. Supersedes the Docker/systemd/Linux framing in this ticket's original question ([ADR 0010](../../../docs/adr/0010-macos-single-process-server.md), amended by this ticket).

### Layout — everything under the user's home

| | Path |
| --- | --- |
| Binary | `~/.local/bin/issues-server` |
| LaunchAgent plist | `~/Library/LaunchAgents/co.trywe.issues.server.plist` |
| Data (**three** files) | `~/Library/Application Support/Issues/` — `issues.sqlite`, `issues.sqlite-wal`, `issues.sqlite-shm`, mode `0700` |
| Config | `~/Library/Application Support/Issues/config.toml` |
| Bootstrap token | `~/Library/Application Support/Issues/bootstrap-token`, `0600`, self-deleting |
| Logs | `~/Library/Logs/Issues/` |

**SQLite is not one file.** WAL mode (ticket 04, chosen to serialise writers) means three, and that governs every instruction about copying, moving or backing up the data — it is the thing an admin gets wrong first.

Because nothing lands in a system directory, **the install is rootless**: no `_issues` service account, no admin password, no system-domain package. That is a genuine simplification over the daemon layout.

### Process management: `LaunchAgent`

`RunAtLoad: true`, `KeepAlive: { SuccessfulExit: false }` (restart on crash, not on clean stop), `ThrottleInterval: 10` so a crash loop cannot spin.

**The availability consequence, recorded because it is the main cost of this shape**: a `LaunchAgent` runs only inside a login session. After a reboot the server stays down until someone logs in, and it stops when that user logs out. For an always-on Instance this must be mitigated at the OS level, and the deployment docs must say so plainly:

- **Enable automatic login** for the account that runs the server, and
- enable **restart after power failure** in Energy Saver settings.

Without both, an unattended reboot silently takes the Instance offline until a human notices. A `LaunchDaemon` running as a dedicated service user would not have this problem, and was the rejected alternative; it was rejected to keep every file under the user's home per the standard macOS per-user convention.

### Distribution

A **signed and notarized `.pkg`**, user-domain. Notarization is not optional polish: Gatekeeper blocks an unsigned binary downloaded from the internet, a macOS-specific hurdle with no Linux equivalent.

**macOS 26, Apple silicon only**, following from the latest-released-only policy rather than being a separate decision. Named casualty: repurposing an old Intel Mac mini as the server box — exactly what someone would want to do — is out.

**The MCP executable does not ship in the server package.** It runs beside the agent, on whatever Mac the human uses, which usually is not the server. Ticket 12's "ships in the same distribution" is narrowed here to: distributed with the client app, not the server installer.

### Configuration

**TOML at `~/Library/Application Support/Issues/config.toml`, with `ISSUES_*` environment variables overriding it.** Precedence: env > file > defaults.

Env-only is the tempting cloud-native answer and is wrong for launchd specifically: setting an environment variable means editing a plist and reloading the agent, which is a miserable way to change a port. Env overrides remain for secrets and for ticket 07's bootstrap seeding.

### Logging and the bootstrap token

Log to stdout/stderr; launchd captures via `StandardOutPath` / `StandardErrorPath` into `~/Library/Logs/Issues/`, rotated by a `newsyslog.d` drop-in — the platform-native path, and less code than in-process rotation.

**The bootstrap token is additionally written to `~/Library/Application Support/Issues/bootstrap-token`, mode `0600`, deleted the moment it is used or expires.** Telling an admin to grep a log for a secret is fragile and encourages leaving secrets in logs; a file they `cat` once, which removes itself, is better on both counts. Ticket 07's requirement that the token be reachable by someone who did not run the binary interactively is satisfied by this file, not by the log.

### Networking

**Bind to `127.0.0.1` by default.** The server must not be exposable to a network in cleartext by an admin who has not set up a proxy yet — the failure mode should be "I can't reach it from my laptop", not "I have been serving bearer tokens over the LAN for a month". A public bind requires an explicit config change.

**Caddy is the documented reverse proxy**: automatic Let's Encrypt certificates and a two-line config, against nginx's manual certificate lifecycle. Terminating TLS in the server itself would mean owning ACME, renewal and certificate storage in Swift — a lot of code for something Caddy does properly. Ticket 07's rules stand: plaintext tokens refused unless `ISSUES_ALLOW_INSECURE=true`, and `X-Forwarded-Proto` trusted only from configured upstreams.

### Backup and restore

**`issues-server backup <path>` uses SQLite's online backup API (`VACUUM INTO`)**, producing a single consistent file while the server runs, with no downtime.

**Naive `cp` of the data directory is explicitly unsupported.** A live WAL database holds committed data in the `-wal` file, so copying the files non-atomically — or copying only `issues.sqlite` — yields a corrupt or silently stale backup. It appears to work right up until you need it. This corrects [ADR 0010](../../../docs/adr/0010-macos-single-process-server.md), which originally claimed backup was copying a file.

**`issues-server restore <path>`** requires the agent stopped, validates the file is a readable Issues database at a known schema version, and refuses to overwrite without `--force`.

### Instance epoch — restore must not silently break sync

The pull watermark is a monotonic sequence (ticket 08). Restoring an older backup **rewinds the counter**, so sequence numbers get reused for different changes: a client holding watermark 900 against a server restored to 400 sees `seq > 900` return empty **forever**, believing it is current while silently diverging. There is no error anywhere.

**The watermark therefore encodes an instance epoch — `epoch:seq`** (it is already opaque per ticket 06). `restore` generates a **new epoch**, and any client presenting a stale epoch is told to full-resync — the escape hatch ticket 08 already defines, including its rule that a full resync never clears the pending queue. This converts a silent permanent divergence into a one-time resync.

### Upgrades and migrations

Re-run the `.pkg`: it stops the agent, replaces the binary, restarts. **GRDB's `DatabaseMigrator` runs automatically at startup** — appropriate for single-tenant, single-box software with no fleet to coordinate and no DBA to run a manual step.

**An automatic backup is taken immediately before any migration**, retained until the next successful start. Auto-migration is the one thing here that could destroy data with no recovery path; the backup makes a failed migration annoying rather than terminal.

### Subcommands

`serve` (default), `backup <path>`, `restore <path>`, `admin reset-password <email>`, `config validate`, `version`.

`config validate` earns its place because a TOML typo that only surfaces as an agent which won't start is miserable to diagnose through launchd.

### Uninstall

**`issues-server uninstall`** unloads and removes the agent, the plist and the binary, and **leaves the data directory in place, reporting its path**. Deleting someone's issue tracker as a side effect of removing software is hostile; `--purge` exists for people who mean it. A `.pkg` cannot uninstall itself, so this is a subcommand rather than an installer feature.
