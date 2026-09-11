import Core
import Foundation
import GRDB

/// Serves the change stream.
///
/// One unified stream across entity types rather than one per type: causal order
/// matters coming down too, and one watermark is one resumable position rather than
/// six that can skew apart (ticket 08).
struct SyncPullService: Sendable {
    let database: AppDatabase

    static let defaultLimit = 500
    static let maximumLimit = 1000

    /// Reads a page of changes after `since`.
    ///
    /// A client's own writes are **not** filtered out by device. They return with
    /// authoritative timestamps and any normalisation, so a client that mis-tracked
    /// its own write self-heals; filtering would save a little bandwidth and create
    /// a bug class where a partially-applied push leaves a client permanently wrong.
    func page(since: Watermark?, limit: Int) throws -> SyncPullResponse {
        let epoch: String = try InstanceRepository(database: database).epoch()

        if let since, since.epoch != epoch {
            // After a restore the sequence is rewound, so a stale epoch must force a
            // full resync rather than silently returning nothing forever.
            throw ProblemError(
                status: .conflict, type: Problem.staleEpochType, title: "Stale epoch",
                detail: "This instance was restored; discard local records and resync.")
        }

        let bounded: Int = min(max(limit, 1), Self.maximumLimit)
        let after: Int = since?.sequence ?? 0

        return try database.reader.read { db in
            // One extra row, to learn whether another page exists without a count.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT entity, entity_id, seq FROM change_cursor
                    WHERE seq > ? ORDER BY seq LIMIT ?
                    """,
                arguments: [after, bounded + 1])

            let hasMore: Bool = rows.count > bounded
            let page = hasMore ? Array(rows.prefix(bounded)) : rows

            var changes: [SyncChange] = []
            var highest: Int = after
            for row in page {
                let sequence: Int = row["seq"]
                highest = max(highest, sequence)
                guard let entity = SyncEntity(rawValue: row["entity"]),
                    let id = UUID(uuidString: row["entity_id"])
                else { continue }
                if let change = try Self.change(db, entity: entity, id: id) {
                    changes.append(change)
                }
            }

            let watermark =
                Watermark(epoch: epoch, sequence: highest)
                ?? Watermark(epoch: epoch, sequence: 0)!
            return SyncPullResponse(
                changes: changes, nextWatermark: watermark, hasMore: hasMore)
        }
    }

    /// Loads one entity as a change entry.
    ///
    /// A tombstoned entity arrives as `deleted: true` with **no record**: the client
    /// needs only to mark its copy deleted, and withholding the record means a
    /// deleted comment's text is not served again.
    private static func change(_ db: Database, entity: SyncEntity, id: UUID) throws -> SyncChange? {
        switch entity {
        case .issue:
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT i.*, p.key AS project_key FROM issue i
                        JOIN project p ON p.id = i.project_id WHERE i.id = ?
                        """,
                    arguments: [id.uuidString])
            else { return nil }
            let record = try IssueRepository.issue(from: row)
            return SyncChange(
                entity: .issue, id: id, deleted: record.isDeleted,
                record: record.isDeleted ? nil : .issue(record))

        case .comment:
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM comment WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            let record = try CommentRepository.comment(from: row)
            return SyncChange(
                entity: .comment, id: id, deleted: record.isDeleted,
                record: record.isDeleted ? nil : .comment(record))

        case .label:
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM label WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            let record = try LabelRepository.label(from: row)
            let deleted: Bool = record.deletedAt != nil
            return SyncChange(
                entity: .label, id: id, deleted: deleted,
                record: deleted ? nil : .label(record))

        case .issueLabel:
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM issue_label WHERE id = ?",
                    arguments: [id.uuidString])
            else { return nil }
            let record = try Self.issueLabel(from: row)
            return SyncChange(
                entity: .issueLabel, id: id, deleted: record.isDeleted,
                record: record.isDeleted ? nil : .issueLabel(record))

        case .project:
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM project WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            // Projects archive rather than delete, so there is no tombstone here.
            return SyncChange(
                entity: .project, id: id, deleted: false,
                record: .project(try ProjectRepository.project(from: row)))

        case .user:
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM user WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            // Users deactivate rather than delete, so there is no tombstone here.
            return SyncChange(
                entity: .user, id: id, deleted: false,
                record: .user(try UserRepository.user(from: row)))
        }
    }

    static func issueLabel(from row: Row) throws -> IssueLabel {
        guard let uuid = UUID(uuidString: row["id"]),
            let issueUUID = UUID(uuidString: row["issue_id"]),
            let labelUUID = UUID(uuidString: row["label_id"])
        else {
            throw DatabaseError(message: "Malformed issue_label row: \(row)")
        }
        return IssueLabel(
            id: ID<IssueLabel>(uuid),
            issueId: Issue.ID(issueUUID),
            labelId: Label.ID(labelUUID),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            deletedAt: row["deleted_at"]
        )
    }
}
