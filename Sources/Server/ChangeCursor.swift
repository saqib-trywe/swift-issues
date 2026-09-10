import Core
import GRDB

/// Records that an entity changed, advancing the server's change sequence.
///
/// Always called **inside the caller's transaction**, never on its own. Applying a
/// change and recording it must happen together or not at all: losing that does
/// not crash, it produces a server whose change stream silently disagrees with its
/// own data, discovered days later by a client that is quietly missing records.
/// ADR 0008 calls this the most expensive invariant to get wrong.
enum ChangeCursor {

    /// Moves this entity to the head of the change stream and returns its new
    /// sequence.
    ///
    /// One row per entity, upserted rather than appended: a history would return
    /// the same current record repeatedly, since last-write-wins convergence only
    /// cares about the endpoint. Taking `MAX(seq) + 1` is safe because SQLite in
    /// WAL mode serialises writers, which is a large part of why ADR 0010 chose it.
    @discardableResult
    static func record(_ db: Database, entity: SyncEntity, id: String) throws -> Int {
        let next = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM change_cursor") ?? 0) + 1
        try db.execute(
            sql: """
                INSERT INTO change_cursor (entity, entity_id, seq) VALUES (?, ?, ?)
                ON CONFLICT (entity, entity_id) DO UPDATE SET seq = excluded.seq
                """,
            arguments: [entity.rawValue, id, next])
        return next
    }
}
