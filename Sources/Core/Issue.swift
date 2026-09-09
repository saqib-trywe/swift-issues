import Foundation

/// A single unit of trackable work within a Project.
///
/// An Issue belongs to exactly one Project for its whole life and cannot be moved
/// between Projects: a move would rewrite its Issue Key and invalidate every
/// external reference. See CONTEXT.md and ticket 01.
public struct Issue: Hashable, Sendable, Codable, Identifiable {
    public typealias ID = Core.ID<Issue>

    public let id: ID
    /// `nil` until the server assigns one on first sync, so an offline-created
    /// Issue is representable without a sentinel. See ADR 0003.
    public var key: IssueKey?
    public let projectId: Project.ID
    public var title: String
    /// Markdown source. Rendered by clients; the server never renders it, so
    /// there is no HTML pipeline and no sanitiser to keep patched.
    public var description: String
    public var status: Status
    public var priority: Priority
    /// Set at creation and immutable thereafter.
    public let reporterId: User.ID
    /// At most one. Shared responsibility is deliberately not expressible.
    public var assigneeId: User.ID?
    /// A calendar day, not an instant: it does not shift with the reader's
    /// timezone.
    public var dueDate: CivilDate?
    /// Set server-side from the writing token's kind; immutable, so it never
    /// participates in last-write-wins.
    public let via: Via
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: ID,
        key: IssueKey? = nil,
        projectId: Project.ID,
        title: String,
        description: String,
        status: Status,
        priority: Priority,
        reporterId: User.ID,
        assigneeId: User.ID? = nil,
        dueDate: CivilDate? = nil,
        via: Via,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.projectId = projectId
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.reporterId = reporterId
        self.assigneeId = assigneeId
        self.dueDate = dueDate
        self.via = via
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
