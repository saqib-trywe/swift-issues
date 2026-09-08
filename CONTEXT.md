# Issues

A lightweight, self-hosted, multi-user issue tracker in the spirit of Jira/Linear: native Swift clients (macOS, iOS, iPadOS, CLI, MCP) built over a single HTTP API server.

## Language

**Instance**:
A single deployed server, with its own database, serving exactly one team. v1 has no multi-tenant support within one Instance.
_Avoid_: Workspace, organization, tenant

**Project**:
A named container that groups related Issues for one team; the top-level unit of organization in v1 (no cross-project epics). Retired Projects are archived, never deleted.
_Avoid_: Board, workspace

**Issue**:
A single unit of trackable work within a Project, carrying a title, description, status, assignee, reporter, priority, labels, and due date. An Issue belongs to exactly one Project for its whole life and cannot be moved between Projects.
_Avoid_: Ticket, task, story (v1 has no separate Epic/Story/Task hierarchy — everything trackable is an Issue)

**Issue Key**:
The short human-facing identifier for an Issue, formed from its Project's key and a per-Project number (`PROJ-142`). Permanent: it is never changed and never reused, even after the Issue is deleted.
_Avoid_: Issue ID (that is the internal identifier), reference, number

**Status**:
One value from a fixed, non-configurable set — Todo, In Progress, Done, Cancelled — describing an Issue's progress. Each value is either open or closed, so work can be filtered without naming individual values. Cancelled means abandoned, as distinct from Done. v1 does not support custom per-project workflows.
_Avoid_: Workflow state, stage

**Priority**:
One value from a fixed, ordered set — None, Low, Medium, High, Urgent — expressing how urgent an Issue is relative to others. Not configurable per Project, so ordering holds across the Instance. Defaults to None.
_Avoid_: Severity, importance, rank, triage level

**Label**:
A named, coloured tag defined within a Project and applied to Issues in that Project. Labels are managed values rather than free text, so they can be renamed and recoloured; a Label can only be applied to Issues in the Project that owns it.
_Avoid_: Tag, component, category, epic

**Reporter**:
The User who created an Issue. Set once at creation and never changes.
_Avoid_: Creator, author, owner, submitter

**Assignee**:
The single User currently responsible for an Issue, or nobody. An Issue has at most one Assignee — shared responsibility is deliberately not expressible.
_Avoid_: Owner, resolver, assignees (plural)

**Due Date**:
The calendar day an Issue is expected to be finished. A day, not an instant: it does not shift with the reader's timezone.
_Avoid_: Deadline, target date, ETA

**Comment**:
A timestamped, user-authored note attached to an Issue, forming its discussion thread. Editable by its author and deletable by its author or an Admin; deletion removes its text.
_Avoid_: Note, activity entry

**Member / Admin**:
The two roles a User can hold within an Instance. Admins manage the Instance (users, projects); Members do tracker work. No finer-grained per-field permissions in v1. A User who leaves is deactivated, never deleted.
_Avoid_: Owner, viewer, guest

**Agent**:
An automated client acting on behalf of a User through the MCP interface. An Agent is a distinct actor from the User who created it, holding strictly less authority than that User regardless of their role, and everything it writes is marked as Agent-authored.
_Avoid_: Bot, integration, service account, robot user
