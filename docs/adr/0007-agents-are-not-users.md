# Agents are not Users: agent tokens carry a fixed reduced capability profile

A personal access token normally carries its owner's full permissions, which would mean an Admin's MCP agent can create accounts and deactivate people. Instead, **`agent`-kind tokens get a fixed, non-configurable capability profile** — read and write Issues, Comments and Labels; never user management, never delete, never Instance administration — irrespective of the owner's role, with a second `agent-readonly` profile for observe-only agents. The MCP tool surface reinforces this by **exposing no destructive tools at all** (`update_issue` with `status: cancelled` is an agent's reversible "make it go away"), and agent tokens are the one identity subject to rate limiting (60 req/min, burst 120).

## Considered Options

- **Agents inherit their owner's permissions**, consistent with every other token. Rejected: handing an autonomous process the same authority as a human Admin is a different risk class from handing it to the human, and the blast radius of a misparsed instruction is unbounded.
- **A general scope system** letting each token be granted specific capabilities. Rejected: that genuinely would contradict the no-granular-permissions rule, and it puts a security decision in front of every user at token-creation time — the point at which people click through.

## Consequences

- This is **not** a retreat from "no fine-grained permissions" ([CONTEXT.md](../../CONTEXT.md), ADR 0001). That rule governs **Users**. An agent is a distinct actor class, and the model now says so: two fixed profiles, nothing configurable, no per-field grants, no custom roles.
- Issue and Comment carry `via: human | agent`, set server-side from the writing token's kind. This amended the resolved ticket 01 domain model deliberately — without it, an agent's work is indistinguishable from its owner's, and the field cannot be backfilled later.
- **An agent that genuinely needs to deactivate a user cannot.** Someone will want this. The answer is to widen the fixed profile in a later version, not to introduce configurable scopes.
- Rate limiting exists for agent tokens and nowhere else, which looks inconsistent with ADR 0005 until you note the reasoning there rested on every caller being an identifiable team member who will not hammer the server. An agent is identifiable and will hammer the server anyway.
- MCP list tools return a **compact projection rather than the raw API payload**, knowingly deviating from the rule set in ticket 11. Agents have a hard context budget that CLI users do not; a list of 50 full Markdown descriptions can consume a whole context window. Confined to the MCP layer so the API needs no sparse-fieldset feature.
