import Foundation

/// The body of a create.
///
/// `reporterId` is absent deliberately: it is set server-side from the
/// authenticated caller and immutable thereafter, so it is not a caller's to
/// supply. The id lives in the path, not the body.
public struct IssueCreate: Encodable, Sendable {
    public var projectId: Project.ID
    public var title: String
    public var description: String
    public var status: Status
    public var priority: Priority
    public var assigneeId: User.ID?
    public var dueDate: CivilDate?
    public var labelIds: [Label.ID]

    /// Defaults follow ticket 01: title is the only field a human must supply,
    /// status starts at `todo`, and priority starts at `none` — a tracker where
    /// everything is born "medium" teaches people that priority is noise.
    public init(
        projectId: Project.ID,
        title: String,
        description: String = "",
        status: Status = .todo,
        priority: Priority = .none,
        assigneeId: User.ID? = nil,
        dueDate: CivilDate? = nil,
        labelIds: [Label.ID] = []
    ) {
        self.projectId = projectId
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.assigneeId = assigneeId
        self.dueDate = dueDate
        self.labelIds = labelIds
    }
}

/// The body of a patch, in JSON Merge Patch form.
///
/// Non-nullable fields use `Settable`; nullable ones use `Patchable`, so
/// "unassign" and "leave the assignee alone" are different values and "clear the
/// status" cannot be expressed at all.
public struct IssuePatch: Encodable, Sendable {
    public var title: Settable<String> = .unchanged
    public var description: Settable<String> = .unchanged
    public var status: Settable<Status> = .unchanged
    public var priority: Settable<Priority> = .unchanged
    public var assigneeId: Patchable<User.ID> = .unchanged
    public var dueDate: Patchable<CivilDate> = .unchanged

    public init() {}

    /// Whether this patch would change anything. Useful for skipping a pointless
    /// round trip, and for the offline queue's coalescing.
    public var isEmpty: Bool {
        title.isUnchanged && description.isUnchanged && status.isUnchanged
            && priority.isUnchanged && assigneeId == .unchanged && dueDate == .unchanged
    }
}

/// The body of a label membership change.
///
/// A delta rather than a replacement set, so two people concurrently adding
/// different labels both survive. See ADR 0003.
public struct LabelDelta: Encodable, Sendable {
    public var add: [Label.ID]
    public var remove: [Label.ID]

    public init(add: [Label.ID] = [], remove: [Label.ID] = []) {
        self.add = add
        self.remove = remove
    }
}

extension IssueEndpoints {

    public static func create(id: Issue.ID, _ body: IssueCreate) throws -> HTTPRequest {
        HTTPRequest(
            method: "PUT",
            path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(body)
        )
    }

    public static func patch(id: Issue.ID, _ body: IssuePatch) throws -> HTTPRequest {
        HTTPRequest(
            method: "PATCH",
            path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/merge-patch+json"],
            body: try JSONCoders.encoder.encode(body)
        )
    }

    public static func changeLabels(
        id: Issue.ID, add: [Label.ID] = [], remove: [Label.ID] = []
    ) throws -> HTTPRequest {
        HTTPRequest(
            method: "PATCH",
            path: "\(base)/\(id.rawValue.uuidString)/labels",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(LabelDelta(add: add, remove: remove))
        )
    }
}
