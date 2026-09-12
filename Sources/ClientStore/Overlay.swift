import Core
import Foundation
import GRDB

/// A field of an Issue that can be locally changed.
///
/// Named per field because the UI needs to say *which* values are unsent — that is
/// what conflict presentation rests on, and it is the reason ticket 05 keeps the
/// queue as the record of what is dirty rather than storing a second copy.
public enum IssueField: String, Sendable, Hashable, CaseIterable {
    case title
    case description
    case status
    case priority
    case assignee
    case dueDate
}

/// A record as the user should see it: the server's version with their own unsent
/// changes applied on top.
public struct Overlaid<Record: Sendable>: Sendable {
    public let record: Record
    /// Fields carrying unsent changes.
    public let dirty: Set<IssueField>
    /// Created here and never yet accepted by the server.
    public let isUnsentCreate: Bool
    /// Deleted here and not yet accepted. The base row is untouched, so a rejected
    /// delete needs nothing undone.
    public let isUnsentDelete: Bool
    /// A pending change to this record was rejected and is waiting for repair.
    public let isQuarantined: Bool

    public var hasUnsentChanges: Bool {
        !dirty.isEmpty || isUnsentCreate || isUnsentDelete
    }
}

extension ReplicaDatabase {

    /// One issue, with unsent changes applied.
    ///
    /// Returns `nil` for an issue that does not exist, or one the server has
    /// tombstoned. A *locally* deleted issue still comes back, flagged — the caller
    /// decides whether to hide it, and a list does while a detail view showing
    /// "deleting…" might not.
    public func issue(_ id: Issue.ID) throws -> Overlaid<Issue>? {
        try reader.read { db in
            guard let base = try Self.issueRow(db, id: id) else { return nil }
            let pending = try Self.pendingOperations(db, for: [id.rawValue])
            return Self.overlay(base, with: pending[id.rawValue] ?? [])
        }
    }

    /// Every issue in a project, with unsent changes applied.
    ///
    /// The base rows come from SQL — which is why a local create still writes a row
    /// — and the overlay is applied to the page that comes back.
    public func issues(
        in projectId: Project.ID? = nil,
        includingDeleted: Bool = false
    ) throws -> [Overlaid<Issue>] {
        try reader.read { db in
            var sql = "SELECT * FROM issue WHERE deleted_at IS NULL"
            var arguments: [any DatabaseValueConvertible] = []
            if includingDeleted { sql = "SELECT * FROM issue WHERE 1 = 1" }
            if let projectId {
                sql += " AND project_id = ?"
                arguments.append(projectId.rawValue.uuidString)
            }
            sql += " ORDER BY created_at DESC, id DESC"

            let bases = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .compactMap(Self.issue(from:))
            let pending = try Self.pendingOperations(db, for: bases.map(\.id.rawValue))

            return bases.map { base in
                Self.overlay(base, with: pending[base.id.rawValue] ?? [])
            }
        }
    }

    /// Which fields of an issue carry unsent changes.
    ///
    /// Separate from the record so a UI can mark individual fields without
    /// re-deriving the whole overlay.
    public func dirtyFields(of id: Issue.ID) throws -> Set<IssueField> {
        try issue(id)?.dirty ?? []
    }

    // MARK: Applying the queue

    /// Applies one entity's pending operations to its base record, in queue order.
    ///
    /// Quarantined operations are applied too, deliberately: the user typed that
    /// text and it is still theirs to repair, so hiding it would make a rejection
    /// look like their edit had been thrown away. The `isQuarantined` flag is how
    /// the UI says it has not gone anywhere.
    static func overlay(_ base: Issue, with pending: [PendingOperation]) -> Overlaid<Issue> {
        var record = base
        var dirty: Set<IssueField> = []
        var isUnsentCreate = false
        var isUnsentDelete = false
        var isQuarantined = false

        for entry in pending {
            if entry.state == .quarantined { isQuarantined = true }

            switch entry.operation {
            case .putIssue(_, _, _, let body):
                // Not yet confirmed, so the row on disk is provisional.
                isUnsentCreate = true
                record.title = body.title
                record.description = body.description
                record.status = body.status
                record.priority = body.priority
                record.assigneeId = body.assigneeId
                record.dueDate = body.dueDate

            case .patchIssue(_, _, _, let body):
                if case .set(let value) = body.title {
                    record.title = value
                    dirty.insert(.title)
                }
                if case .set(let value) = body.description {
                    record.description = value
                    dirty.insert(.description)
                }
                if case .set(let value) = body.status {
                    record.status = value
                    dirty.insert(.status)
                }
                if case .set(let value) = body.priority {
                    record.priority = value
                    dirty.insert(.priority)
                }
                switch body.assigneeId {
                case .set(let value):
                    record.assigneeId = value
                    dirty.insert(.assignee)
                case .cleared:
                    record.assigneeId = nil
                    dirty.insert(.assignee)
                case .unchanged:
                    break
                }
                switch body.dueDate {
                case .set(let value):
                    record.dueDate = value
                    dirty.insert(.dueDate)
                case .cleared:
                    record.dueDate = nil
                    dirty.insert(.dueDate)
                case .unchanged:
                    break
                }

            case .deleteIssue:
                isUnsentDelete = true

            // Operations on other entities cannot change an issue's own fields.
            default:
                break
            }
        }

        return Overlaid(
            record: record, dirty: dirty, isUnsentCreate: isUnsentCreate,
            isUnsentDelete: isUnsentDelete, isQuarantined: isQuarantined)
    }

    /// Pending operations grouped by the entity they target.
    ///
    /// Fetched for the whole page in one query rather than per row: a list of fifty
    /// issues would otherwise be fifty-one queries.
    static func pendingOperations(
        _ db: Database, for ids: [UUID]
    ) throws -> [UUID: [PendingOperation]] {
        guard !ids.isEmpty else { return [:] }

        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM pending_operation
                WHERE entity_id IN (\(placeholders))
                ORDER BY sequence
                """,
            arguments: StatementArguments(ids.map(\.uuidString)))

        return rows.compactMap(pending(from:)).reduce(into: [:]) { grouped, entry in
            grouped[SyncDependencies.target(of: entry.operation).id, default: []].append(entry)
        }
    }

    static func issueRow(_ db: Database, id: Issue.ID) throws -> Issue? {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM issue WHERE id = ?",
                arguments: [id.rawValue.uuidString])
        else { return nil }
        return issue(from: row)
    }

    /// A row that cannot be read is skipped rather than throwing: one malformed
    /// record must not make a whole list unreadable.
    static func issue(from row: Row) -> Issue? {
        guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
            let projectId = (row["project_id"] as String?).flatMap(UUID.init(uuidString:)),
            let reporterId = (row["reporter_id"] as String?).flatMap(UUID.init(uuidString:))
        else { return nil }

        return Issue(
            id: Issue.ID(id),
            key: (row["key"] as String?).flatMap(IssueKey.init),
            projectId: Project.ID(projectId),
            title: row["title"],
            description: row["description"],
            status: Status(wireValue: row["status"]),
            priority: Priority(wireValue: row["priority"]),
            reporterId: User.ID(reporterId),
            assigneeId: (row["assignee_id"] as String?).flatMap(UUID.init(uuidString:))
                .map(User.ID.init),
            dueDate: (row["due_date"] as String?).flatMap { CivilDate(wireValue: $0) },
            via: Via(wireValue: row["via"]),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"])
    }
}
