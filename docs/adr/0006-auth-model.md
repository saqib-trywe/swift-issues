# Opaque revocable tokens, local accounts, and no email dependency

Authentication is **local email + password** with **opaque 256-bit tokens stored hashed server-side** — not JWTs, and with no refresh tokens. The usual case for JWT is letting many services validate a token without a lookup; there is one server here and it already has its database open, so a JWT would buy nothing while costing the ability to revoke, which matters concretely for a lost phone, a deactivated user, or a leaked agent token. Because we are already stateful and revoke instantly, the access/refresh split has nothing left to do, so sessions are a single token with a **60-day idle expiry renewed on use** — deliberately long, because an offline-first client can legitimately be offline for weeks and a short-lived token would lock the app out of its own sync.

## Considered Options

- **JWT with short-lived access tokens plus refresh tokens.** The conventional answer, and what a reviewer will expect. Rejected: unrevocable-by-design in a system whose whole point is a single self-hosted server, and hostile to clients that are offline for extended periods.
- **OIDC/SSO as the primary method.** Rejected for v1 as a genuine lift (discovery, callback handling, claim-to-role mapping) that a single-team tracker doesn't need to launch. Expected to be the first thing a corporate self-hoster asks for, so the model must not assume every User has a password.
- **"First user to register becomes Admin"** for bootstrap. Rejected: on a server exposed before anyone logs in, that is a race an attacker wins. A one-time bootstrap token printed to stdout on first start against an empty database wins instead, with env-var seeding for scripted deploys.
- **SMTP-based password reset.** Rejected: requiring every self-hoster to configure mail before anyone can recover an account is a heavy tax on a deliberately lightweight tool.

## Consequences

- **A sole Admin who forgets their password is locked out of their own Instance**, because there is no email reset path. The server binary must therefore ship `issues-server admin reset-password`, runnable on the host, where filesystem access is the proof of authority. This is a hard prerequisite, not a nice-to-have — it has to exist before anyone can be locked out.
- **Deactivating a User revokes their sessions immediately, stranding any pending offline writes on their device.** Those writes stay local and exportable but never reach the Instance. Accepted: the alternative is letting a deactivated account keep writing.
- **Auth failure never quarantines an operation.** A 401 mid-sync preserves the pending queue intact and moves sync into a "needs re-authentication" state. Quarantine (ADR 0004) means *this write is bad*; these writes are fine and it is the session that is not, so conflating them would ask users to repair dozens of perfectly good writes.
- **Per-account login throttling is a deliberate exception** to the no-rate-limiting decision in [ADR 0005](0005-two-write-paths-one-concurrency-model.md) and ticket 06. That decision rested on every caller being an identifiable team member, which is precisely what an unauthenticated attacker is not. Recorded so the inconsistency reads as intentional.
- **No web UI exists in v1**, so personal access tokens are minted from the macOS app, with `issues auth token create` as the bootstrap path — the one place a password crosses the CLI, since a user with no token cannot call an authenticated API to make one.
