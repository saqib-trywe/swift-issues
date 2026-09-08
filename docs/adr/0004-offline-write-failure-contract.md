# Offline writes replay in causal order, and failures quarantine rather than block

A client's pending-operation queue replays in **causal order** — parents before children — and the server **strictly rejects any reference to an id it has not seen**: an offline Comment on a never-synced Issue is the client's ordering problem, not a dangling reference the server should accept and later reap. When the server refuses an operation (a stale assignee, a validation rule a newer server tightened, a Label whose Project changed underneath it), the client **quarantines** that operation together with the server's error and surfaces it for repair or deliberate discard — never a silent drop, per the same principle as ADR 0001 — and critically, a quarantined operation **does not block the rest of the queue**.

## Consequences

- The offline queue is a **topologically ordered log, not merely a chronological one**. This is a hard requirement on the queue design in ticket 05.
- Operations causally dependent on a quarantined operation are quarantined alongside it; everything independent continues to sync.
- Clients need a visible **"needs attention"** surface. A quarantined write with nowhere to appear is a silently dropped write with extra steps.
- Head-of-line blocking is the specific failure this exists to prevent: one bad record freezing all subsequent sync, invisibly, is how an offline-first app dies without anyone noticing.
- Validation therefore lives in the shared Core package (per ADR 0002) and runs twice — optimistically on the client for fast feedback, authoritatively on the server. The two can legitimately disagree when a server is newer than a client, which is exactly the case quarantine handles.
