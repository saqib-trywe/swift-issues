# Auth model design

Type: grilling
Status: resolved

Blocked by: 01

## Question

Design the auth model: how a User authenticates (password? something else?), how sessions/tokens are issued and refreshed, how long-lived API tokens work for the CLI and MCP interface (which can't do interactive login the way a native app can), and how Member vs Admin roles are enforced at the API layer. Cover the first-Instance bootstrap question (how the first Admin account gets created on a fresh install) if it's sharp enough here; otherwise leave it in the map's fog for a later ticket.

## Resolution

Locked. Rationale for the non-obvious choices is in [ADR 0006](../../../docs/adr/0006-auth-model.md). Note the constraint that shapes several of these: **v1 has no web UI** — the surfaces are Server, native apps, CLI and MCP — so anything that conventionally lives on a settings web page has nowhere to go.

### Authentication

- **Local email + password only.** No OIDC/SSO in v1. Expected to be the most common v1.1 request from anyone deploying into a company that already has SSO, so the model must not assume every User row has a password.
- Hashing is **Argon2id**. Minimum length 12, **no composition rules, no rotation** (current NIST guidance).
- **`Authorization: Bearer <token>`** for every authenticated request.

### Sessions

- **Opaque 256-bit CSPRNG tokens, stored hashed server-side.** Not JWT: the usual argument for JWT is avoiding a lookup across many services, which does not apply to one server that already has its database open — and what you'd buy instead is a token that cannot be revoked without a blocklist that reintroduces the lookup. Revocation is not hypothetical (lost phone, deactivated user, leaked token).
- **No refresh tokens.** The access/refresh split exists to make *stateless* tokens tolerable; we are stateful and revoke instantly, so it would add a second token type and a refresh dance across five clients for nothing.
- **60-day idle expiry, renewed on use** (the per-request lookup is already happening, so sliding is free), with a **1-year absolute cap**. Short-lived tokens would be actively hostile: an offline-first app can legitimately be offline for weeks.
- **Multiple concurrent sessions**, one token per device, each labelled and individually revocable. The sync envelope's `deviceId` is bound to the token at login.

### Personal access tokens (CLI, MCP)

- User-generated, **displayed once**, prefixed `issues_pat_…` so they're greppable in leaked configs, stored hashed, revocable, with a required label, an optional expiry, and a `kind` (human vs agent).
- **Same permissions as their owner** — no granular scopes, consistent with the no-fine-grained-permissions rule.
- **Minting, given no web UI**: the macOS app is the primary place; `issues auth token create` is the bootstrap path. That CLI command accepts an interactive email/password login, because a fresh CLI user with no token cannot call an authenticated API to make one. It is the only place a password crosses the CLI.
- **Admins see that a token exists** — owner, label, kind, created, last-used — and can revoke any of them, but never see a value; nobody can, since only a hash is stored. Revocation after an incident (a leaked agent token) is fully served without exposing values.
- **Last-used is tracked coarsely**, updated only when the stored value is over an hour old, or every authenticated read becomes a write.

### First-Admin bootstrap

- On first start against an **empty database**, the server prints a **one-time bootstrap token to stdout** (the Jenkins `initialAdminPassword` pattern), valid until used or 60 minutes, able only to create the first Admin.
- Plus optional env-var seeding (`ISSUES_BOOTSTRAP_ADMIN_EMAIL` / `…_PASSWORD`) for scripted deploys, since a one-time token in a log is hostile to automation.
- **Rejected**: "first user to register becomes Admin" — on a server exposed before anyone logs in, that is a race an attacker wins.

### Password recovery without email

**No email dependency in v1.** Requiring every self-hoster to configure SMTP before anyone can recover an account is a heavy tax on a lightweight tool.

- Reset is an **Admin action**: the Admin issues a one-time reset token from the app and hands it over by whatever channel the team already uses.
- The hole this leaves, stated plainly: **a sole Admin who forgets their password is locked out of their own Instance.** The server binary therefore ships **`issues-server admin reset-password`**, runnable on the host, where filesystem access is the proof of authority. This must exist before anyone can be locked out.

### Role enforcement

**Both layers, because they cannot express the same things.**

- **Route middleware** carries declarative role requirements (`requires: .admin`), so the permission sits next to the route and cannot be forgotten in a handler.
- **Service layer** enforces ownership rules that need the record loaded — "author or Admin" for comment delete, "reporter or Admin" for issue delete.
- Both surface as **403 with an RFC 9457 problem**, distinct from 401.

### Transport

- The server **assumes TLS is terminated upstream** (reverse proxy is the standard self-host shape) and **refuses to issue or accept tokens over plaintext unless `ISSUES_ALLOW_INSECURE=true`** is explicitly set for local development. Silently accepting bearer tokens in cleartext because a proxy was misconfigured is the failure worth designing against.
- `X-Forwarded-Proto` is trusted **only from configured upstreams**.

### Brute force

**Per-account throttling on failed login and PAT auth**: exponential backoff after 5 consecutive failures, capped at a 15-minute lockout. Counted **per account, not per IP** — per-IP is trivially evaded and punishes everyone behind one NAT. This is a deliberate, narrow exception to ticket 06's no-rate-limiting decision: that reasoning rested on everyone being an identifiable team member, which is exactly what an unauthenticated attacker is not.

**Backfilled while resolving ticket 11** (the CLI had nothing defined to react to):

- A throttled request returns **429 Too Many Requests with a `Retry-After` header**, so clients can render an accurate "try again in N minutes" instead of a bare failure.
- **Login failures must not distinguish "no such account" from "wrong password"** — one message and one timing profile for both, or the endpoint becomes an account enumeration oracle. This is a server-side obligation, not client copy.

### Auth failure while offline writes are pending

- **The pending queue is never discarded on auth failure, and auth failure never quarantines an operation.** A 401 on sync push moves sync into a **"needs re-authentication"** state, leaves the queue intact, and prompts login; on success it replays unchanged. Quarantine (ADR 0004) means *this write is bad, fix it* — but these writes are fine, the session isn't, and asking a user to repair 40 good writes would be absurd. Ticket 06 already reserves top-level 4xx on a batch for auth failure.
- **Deactivating a User revokes their sessions immediately**, and any pending writes on that device can then never reach the server. The client retains them locally and can export them, but they are lost to the Instance. The alternative is letting a deactivated account keep writing; this is a documented consequence, not an oversight.

### Logout

**Logout refuses to proceed silently when the pending queue is non-empty** — it warns, states how many unsynced changes exist, and offers to sync first. Logging out anyway is an explicit destructive confirmation. Logout then **clears the local replica** (a handed-on device must not leave someone's tracker readable on disk) and **deletes the token server-side**, so a stolen copy is dead too.
