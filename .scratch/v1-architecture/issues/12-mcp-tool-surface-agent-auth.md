# MCP tool surface & agent auth

Type: grilling
Status: resolved

Blocked by: 06, 07

## Question

Design the MCP interface's tool surface for agents (create issue, update status/fields, list/search issues, add comment — confirm the exact set and their parameter shapes against the API contract) and how an MCP client authenticates — the same API-token mechanism as the CLI, or something agent-specific? Builds on the resolved [HTTP API contract design](../issues/06-http-api-contract-design.md) and [Auth model design](../issues/07-auth-model-design.md).

## Inherited constraints (from resolved ticket 06)

- MCP gets **no special endpoints** — same REST surface. Tools map onto existing routes; adding server routes for agents would fork the contract.
- Issue Key lookup and `assignee=me`/`none` tokens are available and should shape tool parameters (agents hold keys, not UUIDs).
- Tool write parameters must express Merge Patch's three states: absent = untouched, explicit null = cleared, value = set.
- **Rate limiting is deliberately absent in v1, and MCP is the flagged exception** — an agent in a loop can hammer an endpoint in a way no human does. Decide here whether agent tokens need limits ahead of everyone else.
- Markdown is returned as raw source, which is the ideal form to hand an agent — no rendering step needed.

## Inherited constraints (from resolved ticket 07)

- **Agents use the same personal access token mechanism as the CLI** — no agent-specific auth protocol. The distinguishing feature is the token's `kind` (human vs agent), which exists so an Admin can see and revoke agent tokens at a glance.
- Tokens carry the same permissions as their owning User; there are no granular scopes to hand an agent a narrower capability. If this ticket concludes agents need less authority than their owner, that is a genuine gap to raise rather than design around.
- Admins can list and revoke any token but never see its value.

## Inherited constraints (from resolved ticket 11)

- The CLI settled that **`--json` returns the raw API payload verbatim** rather than a reshaped client-specific schema. MCP tool results should follow the same rule for the same reason: a reshaped schema is a second contract to version.
- **No local cache, no offline support** — the CLI is online-only and stateless, and MCP should be too. Anything else is a second sync implementation.
- Merge Patch's three states need an explicit representation in tool parameters; the CLI chose a separate `unset` mechanism rather than overloading a sentinel value, because a filter token and a clear operation sharing one word is how things get accidentally unassigned.
- Throttled auth returns **429 with `Retry-After`** — agents in a retry loop must honour it rather than hammering.

## Resolution

Locked. The agent-as-distinct-actor decision is recorded in [ADR 0007](../../../docs/adr/0007-agents-are-not-users.md).

### Tool surface

Ten fine-grained tools, one per operation, unprefixed (MCP clients namespace by server):

`list_issues`, `get_issue`, `create_issue`, `update_issue`, `add_comment`, `list_comments`, `list_projects`, `list_labels`, `list_users`, `whoami`.

Fine-grained beats coarse tools with a mode parameter, because agents select by tool name and description and reason about that more reliably than about an argument. `list_users` exists only so an agent can resolve a name to an id for assignment.

**No destructive tools in v1** — no `delete_issue`, no `delete_comment`, no `archive_project`. `update_issue` with `status: cancelled` is an agent's "make it go away", and it is reversible; deletion is a tombstone nobody can undo, and an agent looping on a misparsed instruction is precisely the actor not to hand that to.

### Agent authority

**Agent-kind tokens carry a fixed, non-configurable reduced capability profile** regardless of their owner's role: read and write Issues, Comments and Labels; never user management, never delete, never Instance administration. A second profile, **`agent-readonly`**, exists for observe-only agents.

This is not a retreat from the no-granular-permissions rule — that rule governs **Users**, and an agent is not a user (see [ADR 0007](../../../docs/adr/0007-agents-are-not-users.md)). Two fixed profiles are not a scope system: nothing is configurable, there are no per-field grants and no custom roles. Accepted cost: an agent that genuinely needs to deactivate a user cannot, and someone will eventually want that.

### Attribution

Issue and Comment carry **`via: human | agent`**, set server-side from the writing token's `kind`. This amends the resolved ticket 01 model — see the amendment recorded there.

### Rate limiting

**Agent-kind tokens get a token bucket: 60 requests/minute, burst 120**, returning 429 with `Retry-After` (the mechanism ticket 07 defines). Human tokens remain unlimited. This resolves the exception ticket 06 flagged: the argument that covered humans — everyone is an identifiable team member who will not hammer the server — fails for an agent, which is identifiable and will hammer the server anyway. Tool descriptions must state that `Retry-After` is to be honoured rather than retried through.

### Result shape — a deliberate deviation

**List tools return a compact projection** (key, title, status, priority, assignee, labels, updated) and omit `description`; `get_issue` returns the full record. Default limit 25, max 100.

This knowingly breaks the raw-API-payload rule inherited from ticket 11. That rule exists to avoid maintaining a second schema, which is a real cost — but the constraint here is a hard context budget, and `list_issues` returning 50 issues with full Markdown descriptions can consume an agent's entire context in one call. Done at the MCP layer only: no API change, and no sparse-fieldset feature reopening ticket 06.

### Transport and packaging

**stdio transport, running as a local process** beside the agent, configured by `ISSUES_URL` and `ISSUES_TOKEN` — matching how MCP clients consume servers today and reusing the CLI's credential conventions exactly. A remote/HTTP MCP server would need its own auth, session and transport story and is a separate effort. The MCP executable ships in the same distribution but is **not something the server operator deploys**.

### Errors and confirmation

Errors surface as the RFC 9457 problem's `title`, `detail` and field-level `errors` rendered as plain text an agent can act on — "title must not be empty", not a bare status code. **No elicitation or built-in confirmation**: the MCP host already gates tool calls with its own approval UI, and a second layer double-prompts the user for one action. Quarantine and superseded outcomes never arise here — MCP is online-only with no queue, so it sees ordinary REST responses.
