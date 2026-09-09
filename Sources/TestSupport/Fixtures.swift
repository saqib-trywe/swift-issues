import Core
import Foundation

/// Builders for the six domain entities.
///
/// Every field has a sensible default and is overridable, so a test states only
/// what it cares about. Hand-rolling entities per test file drifts until two
/// files disagree about what a valid Issue is. Ticket 13.
///
/// Linked only by test targets; never shipped.

public enum Fixtures {
    /// A fixed instant, so fixtures are deterministic and tests never depend on
    /// the current time.
    public static let epoch = Date(timeIntervalSince1970: 1_757_000_000.123)
}

extension User {
    public static func fixture(
        id: User.ID = User.ID(),
        email: String = "saqib@example.com",
        displayName: String = "Saqib",
        role: Role = .member,
        active: Bool = true,
        createdAt: Date = Fixtures.epoch,
        updatedAt: Date = Fixtures.epoch
    ) -> User {
        User(
            id: id, email: email, displayName: displayName, role: role,
            active: active, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

extension Project {
    public static func fixture(
        id: Project.ID = Project.ID(),
        key: ProjectKey = ProjectKey("PROJ")!,
        name: String = "Platform",
        description: String = "Server and sync work",
        archived: Bool = false,
        createdAt: Date = Fixtures.epoch,
        updatedAt: Date = Fixtures.epoch
    ) -> Project {
        Project(
            id: id, key: key, name: name, description: description,
            archived: archived, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

extension Label {
    public static func fixture(
        projectId: Project.ID = Project.ID(),
        name: String = "backend",
        color: String = "#2D6CDF",
        createdAt: Date = Fixtures.epoch,
        updatedAt: Date = Fixtures.epoch,
        deletedAt: Date? = nil
    ) -> Label {
        Label(
            id: Label.deriveID(projectId: projectId, name: name),
            projectId: projectId, name: name, color: color,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }
}

extension IssueLabel {
    public static func fixture(
        id: IssueLabel.ID = IssueLabel.ID(),
        issueId: Issue.ID = Issue.ID(),
        labelId: Label.ID = Label.ID(),
        createdAt: Date = Fixtures.epoch,
        updatedAt: Date = Fixtures.epoch,
        deletedAt: Date? = nil
    ) -> IssueLabel {
        IssueLabel(
            id: id, issueId: issueId, labelId: labelId,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }
}

extension Comment {
    public static func fixture(
        id: Comment.ID = Comment.ID(),
        issueId: Issue.ID = Issue.ID(),
        authorId: User.ID = User.ID(),
        body: String? = "Partial index should cover it.",
        via: Via = .human,
        createdAt: Date = Fixtures.epoch,
        updatedAt: Date = Fixtures.epoch,
        deletedAt: Date? = nil
    ) -> Comment {
        Comment(
            id: id, issueId: issueId, authorId: authorId, body: body, via: via,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }
}

extension Issue {
    public static func fixture(
        id: Issue.ID = Issue.ID(),
        key: IssueKey? = IssueKey("PROJ-142"),
        projectId: Project.ID = Project.ID(),
        title: String = "Sync queue stalls behind a quarantined op",
        description: String = "A rejected op blocks its dependents.",
        status: Status = .todo,
        priority: Priority = .none,
        reporterId: User.ID = User.ID(),
        assigneeId: User.ID? = nil,
        dueDate: CivilDate? = nil,
        via: Via = .human,
        createdAt: Date = Fixtures.epoch,
        updatedAt: Date = Fixtures.epoch,
        deletedAt: Date? = nil
    ) -> Issue {
        Issue(
            id: id, key: key, projectId: projectId, title: title,
            description: description, status: status, priority: priority,
            reporterId: reporterId, assigneeId: assigneeId, dueDate: dueDate,
            via: via, createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }
}
