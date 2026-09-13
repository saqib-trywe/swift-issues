import ClientStore
import Core
import Foundation

/// The mutable fields of an Issue, as a form holds them.
///
/// Exists so an editor can be compared against what it started from: ticket 05
/// requires a patch to record **only the fields the user actually changed**. A
/// whole-record snapshot carries stale values for untouched fields, and under
/// per-field last-write-wins those stale values would beat somebody else's newer
/// edit — silently reverting their work.
public struct IssueDraft: Sendable, Equatable {
    public var title: String
    public var description: String
    public var status: Status
    public var priority: Priority
    public var assigneeId: User.ID?
    public var dueDate: CivilDate?

    public init(
        title: String = "",
        description: String = "",
        status: Status = .todo,
        priority: Priority = .none,
        assigneeId: User.ID? = nil,
        dueDate: CivilDate? = nil
    ) {
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.assigneeId = assigneeId
        self.dueDate = dueDate
    }

    /// Seeds a form from what is on screen — which is the overlaid value, so an
    /// edit builds on the user's own unsent changes rather than on the server's
    /// older record.
    public init(from issue: Issue) {
        self.init(
            title: issue.title,
            description: issue.description,
            status: issue.status,
            priority: issue.priority,
            assigneeId: issue.assigneeId,
            dueDate: issue.dueDate)
    }

    /// What the user typed, checked before anything is queued.
    ///
    /// Failing here rather than at the server means an offline edit is refused
    /// while the person is still looking at it, instead of being quarantined hours
    /// later with no context.
    public var validationFailures: [ValidationFailure] {
        Validation.issue(title: title, description: description)
    }

    public var isValid: Bool { validationFailures.isEmpty }

    /// The body for a create.
    public func create(projectId: Project.ID, labelIds: [Label.ID] = []) -> IssueCreate {
        IssueCreate(
            projectId: projectId,
            title: title,
            description: description,
            status: status,
            priority: priority,
            assigneeId: assigneeId,
            dueDate: dueDate,
            labelIds: labelIds)
    }

    /// A patch carrying only what differs from `original`.
    ///
    /// Empty when nothing changed, so a form saved untouched queues nothing — a
    /// no-op operation is a round trip that changes nothing and an `updatedAt`
    /// bump that wins a race it should never have entered.
    public func patch(against original: IssueDraft) -> IssuePatch {
        var patch = IssuePatch()
        if title != original.title { patch.title = .set(title) }
        if description != original.description { patch.description = .set(description) }
        if status != original.status { patch.status = .set(status) }
        if priority != original.priority { patch.priority = .set(priority) }

        if assigneeId != original.assigneeId {
            // Clearing is a value, not an absence — that is the whole point of
            // Merge Patch's third state.
            patch.assigneeId = assigneeId.map { .set($0) } ?? .cleared
        }
        if dueDate != original.dueDate {
            patch.dueDate = dueDate.map { .set($0) } ?? .cleared
        }
        return patch
    }

    /// Whether a field may be edited.
    ///
    /// A leniently-decoded `unknown` value is read-only (ticket 10): offering a
    /// picker would let the user clobber a value this build cannot represent,
    /// which is the very thing lenient decoding exists to prevent.
    public func isReadOnly(_ field: IssueField) -> Bool {
        switch field {
        case .status:
            if case .unknown = status { return true }
        case .priority:
            if case .unknown = priority { return true }
        default:
            break
        }
        return false
    }
}
