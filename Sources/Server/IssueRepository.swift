import Core
import Foundation
import GRDB

/// Persistence for Issues, including Issue Key allocation and the per-field
/// timestamps that per-field last-write-wins is resolved against.
public struct IssueRepository: Sendable {
    let database: AppDatabase

    /// The six mutable scalars. Each carries its own receipt timestamp, so two
    /// clients editing different fields both win rather than one clobbering the
    /// other (ADR 0003).
    static let mutableFields = [
        "title", "description", "status", "priority", "assignee_id", "due_date",
    ]

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Writes a new Issue, allocating its Issue Key from the project's counter.
    ///
    /// The counter is monotonic and never rewound, so a deleted Issue burns its
    /// number: reuse would silently repoint every old reference — commit trailers,
    /// chat messages, bookmarks — at a different Issue.
    public func create(_ issue: Issue) throws -> Issue {
        try database.writer.write { db in
            guard
                let projectKey = try String.fetchOne(
                    db, sql: "SELECT key FROM project WHERE id = ?",
                    arguments: [issue.projectId.rawValue.uuidString]),
                let number = try Int.fetchOne(
                    db, sql: "SELECT next_issue_number FROM project WHERE id = ?",
                    arguments: [issue.projectId.rawValue.uuidString]),
                let key = ProjectKey(projectKey),
                let issueKey = IssueKey(projectKey: key, number: number)
            else {
                throw ProblemError.notFound(detail: "No such project.")
            }

            try db.execute(
                sql: "UPDATE project SET next_issue_number = ? WHERE id = ?",
                arguments: [number + 1, issue.projectId.rawValue.uuidString])

            // Every mutable field starts stamped, so a later patch compares
            // against a real receipt time rather than a null.
            var arguments: [(any DatabaseValueConvertible)?] = [
                issue.id.rawValue.uuidString, number, issue.projectId.rawValue.uuidString,
                issue.title, issue.description, issue.status.wireValue,
                issue.priority.wireValue, issue.reporterId.rawValue.uuidString,
                issue.assigneeId?.rawValue.uuidString, issue.dueDate?.wireValue,
                issue.via.wireValue, issue.createdAt, issue.updatedAt,
            ]
            arguments.append(contentsOf: Self.mutableFields.map { _ in issue.updatedAt })

            try db.execute(
                sql: """
                    INSERT INTO issue
                        (id, key_number, project_id, title, description, status, priority,
                         reporter_id, assignee_id, due_date, via, created_at, updated_at,
                         deleted_at, title_updated_at, description_updated_at,
                         status_updated_at, priority_updated_at, assignee_id_updated_at,
                         due_date_updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: StatementArguments(arguments))

            try ChangeCursor.record(db, entity: .issue, id: issue.id.rawValue.uuidString)

            var created = issue
            created.key = issueKey
            return created
        }
    }

    /// Applies a Merge Patch, stamping **only** the fields it names.
    ///
    /// Stamping an unnamed field would let it start winning conflicts it never
    /// participated in, which is precisely what per-field resolution exists to
    /// prevent.
    public func apply(_ patch: IssuePatch, to id: Issue.ID, at now: Date) throws -> Issue? {
        try database.writer.write { db in
            guard try Self.row(db, id: id) != nil else { return nil }

            var assignments: [String] = []
            var arguments: [(any DatabaseValueConvertible)?] = []

            func set(_ column: String, _ value: (any DatabaseValueConvertible)?) {
                assignments.append("\(column) = ?")
                arguments.append(value)
                assignments.append("\(column)_updated_at = ?")
                arguments.append(now)
            }

            if case .set(let value) = patch.title { set("title", value) }
            if case .set(let value) = patch.description { set("description", value) }
            if case .set(let value) = patch.status { set("status", value.wireValue) }
            if case .set(let value) = patch.priority { set("priority", value.wireValue) }
            switch patch.assigneeId {
            case .set(let value): set("assignee_id", value.rawValue.uuidString)
            case .cleared: set("assignee_id", nil)
            case .unchanged: break
            }
            switch patch.dueDate {
            case .set(let value): set("due_date", value.wireValue)
            case .cleared: set("due_date", nil)
            case .unchanged: break
            }

            assignments.append("updated_at = ?")
            arguments.append(now)

            try db.execute(
                sql: "UPDATE issue SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                arguments: StatementArguments(arguments + [id.rawValue.uuidString]))

            try ChangeCursor.record(db, entity: .issue, id: id.rawValue.uuidString)
            return try Self.row(db, id: id).map(Self.issue(from:))
        }
    }

    /// Tombstones the Issue. Nothing is hard-deleted: to a syncing client an absent
    /// row and a never-seen row are indistinguishable, so hard deletes resurrect.
    public func delete(_ id: Issue.ID, at now: Date) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE issue SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.rawValue.uuidString])
            try ChangeCursor.record(db, entity: .issue, id: id.rawValue.uuidString)
        }
    }

    /// Returns tombstoned Issues too, so a caller can tell "gone" from "never
    /// existed" and answer 410 rather than 404.
    public func find(_ id: Issue.ID) throws -> Issue? {
        try database.reader.read { db in
            try Self.row(db, id: id).map(Self.issue(from:))
        }
    }

    /// Humans and agents hold keys, not UUIDs.
    public func find(key: IssueKey) throws -> Issue? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT i.*, p.key AS project_key FROM issue i
                        JOIN project p ON p.id = i.project_id
                        WHERE p.key = ? AND i.key_number = ?
                        """,
                    arguments: [key.projectKey.wireValue, key.number])
            else { return nil }
            return try Self.issue(from: row)
        }
    }

    /// The per-field receipt timestamps, keyed by column. Sync machinery rather
    /// than domain state, which is why it is not on Core's `Issue`.
    public func fieldTimestamps(_ id: Issue.ID) throws -> [String: Date] {
        try database.reader.read { db in
            guard let row = try Self.row(db, id: id) else { return [:] }
            return Dictionary(
                uniqueKeysWithValues: Self.mutableFields.compactMap { field in
                    (row["\(field)_updated_at"] as Date?).map { (field, $0) }
                })
        }
    }

    private static func row(_ db: Database, id: Issue.ID) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT i.*, p.key AS project_key FROM issue i
                JOIN project p ON p.id = i.project_id
                WHERE i.id = ?
                """,
            arguments: [id.rawValue.uuidString])
    }

    static func issue(from row: Row) throws -> Issue {
        guard let uuid = UUID(uuidString: row["id"]),
            let projectUUID = UUID(uuidString: row["project_id"]),
            let reporterUUID = UUID(uuidString: row["reporter_id"])
        else {
            throw DatabaseError(message: "Malformed issue row: \(row)")
        }

        var key: IssueKey?
        if let number: Int = row["key_number"], let projectKey = ProjectKey(row["project_key"]) {
            key = IssueKey(projectKey: projectKey, number: number)
        }

        return Issue(
            id: Issue.ID(uuid),
            key: key,
            projectId: Project.ID(projectUUID),
            title: row["title"],
            description: row["description"],
            status: Status(wireValue: row["status"]),
            priority: Priority(wireValue: row["priority"]),
            reporterId: User.ID(reporterUUID),
            assigneeId: (row["assignee_id"] as String?).flatMap(UUID.init(uuidString:))
                .map(User.ID.init),
            dueDate: (row["due_date"] as String?).flatMap(CivilDate.init(wireValue:)),
            via: Via(wireValue: row["via"]),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"]
        )
    }
}
