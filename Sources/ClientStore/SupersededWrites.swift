import Core
import Foundation
import GRDB

/// Why a write can never be sent.
public enum SupersededReason: String, Codable, Hashable, Sendable {
    /// The server answered `superseded`: valid, but the entity is tombstoned.
    case rejectedByServer
    /// A tombstone arrived on a pull while this was still queued.
    case deletedElsewhere
    /// Dropped because something it depended on was itself superseded — a pending
    /// comment on an issue that has gone.
    case dependencyRemoved
}

/// A write that cannot ever succeed, kept so the user can recover their text.
public struct SupersededRecord: Sendable {
    public let opId: UUID
    public let operation: SyncOperation
    /// What won, when the server said so.
    public let current: SyncRecord?
    public let reason: SupersededReason
    public let occurredAt: Date
}

extension ReplicaDatabase {

    /// Everything the user has lost to a deletion, newest first.
    ///
    /// Kept until dismissed rather than expiring: it is their text, and deciding
    /// when they have finished with it is not ours to make on a timer.
    public func supersededWrites() throws -> [SupersededRecord] {
        try reader.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM superseded_write ORDER BY occurred_at DESC"
            ).compactMap(Self.superseded(from:))
        }
    }

    /// Forgets one, once the user has copied their text out or decided not to.
    public func dismissSuperseded(_ opId: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM superseded_write WHERE op_id = ?", arguments: [opId.uuidString])
        }
    }

    /// Records a write as lost. Does not touch the queue; callers discard separately.
    public func recordSuperseded(
        _ operation: SyncOperation,
        current: SyncRecord?,
        reason: SupersededReason,
        at now: Date = Date()
    ) throws {
        try writer.write { db in
            try Self.recordSuperseded(
                operation, current: current, reason: reason, at: now, in: db)
        }
    }

    static func recordSuperseded(
        _ operation: SyncOperation,
        current: SyncRecord?,
        reason: SupersededReason,
        at now: Date,
        in db: Database
    ) throws {
        let reference = SyncDependencies.target(of: operation)
        try db.execute(
            sql: """
                INSERT INTO superseded_write
                    (op_id, entity_type, entity_id, payload, current, reason, occurred_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (op_id) DO NOTHING
                """,
            arguments: [
                operation.opId.uuidString, reference.entity.rawValue, reference.id.uuidString,
                String(decoding: try JSONCoders.encoder.encode(operation), as: UTF8.self),
                try current.map {
                    String(decoding: try JSONCoders.encoder.encode($0), as: UTF8.self)
                },
                reason.rawValue, now,
            ])
    }

    /// Drops pending work against entities the server has tombstoned, and records it.
    ///
    /// Ticket 05: quarantine means *repair and retry*, and there is nothing left to
    /// retry against — leaving these pending produces an operation that fails
    /// forever. Applied transitively, so a pending comment on a deleted issue goes
    /// the same way, which falls straight out of the derived dependency rule.
    ///
    /// Returns what was dropped, so a sync can report it.
    @discardableResult
    func supersedePending(
        tombstoned: [SyncReference], at now: Date = Date()
    ) throws -> [SupersededRecord] {
        guard !tombstoned.isEmpty else { return [] }

        return try writer.write { db in
            let queued = try Row.fetchAll(
                db, sql: "SELECT * FROM pending_operation ORDER BY sequence"
            ).compactMap(Self.pending(from:))
            guard !queued.isEmpty else { return [] }

            let gone = Set(tombstoned)
            // Direct casualties: anything writing to, or naming, a tombstoned entity.
            let doomed = queued.filter { entry in
                gone.contains(SyncDependencies.target(of: entry.operation))
                    || !SyncDependencies.prerequisites(of: entry.operation).isDisjoint(with: gone)
            }
            guard !doomed.isEmpty else { return [] }

            // And everything downstream of those, by the same rule that decides what
            // a quarantined operation holds back.
            let transitive = SyncDependencies.blocked(
                by: Set(doomed.map(\.operation.opId)), in: queued.map(\.operation))

            var records: [SupersededRecord] = []
            for entry in queued {
                let isDirect = doomed.contains { $0.operation.opId == entry.operation.opId }
                guard isDirect || transitive.contains(entry.operation.opId) else { continue }

                let reason: SupersededReason = isDirect ? .deletedElsewhere : .dependencyRemoved
                try Self.recordSuperseded(
                    entry.operation, current: nil, reason: reason, at: now, in: db)
                try db.execute(
                    sql: "DELETE FROM pending_operation WHERE op_id = ?",
                    arguments: [entry.operation.opId.uuidString])

                records.append(
                    SupersededRecord(
                        opId: entry.operation.opId, operation: entry.operation,
                        current: nil, reason: reason, occurredAt: now))
            }
            return records
        }
    }

    static func superseded(from row: Row) -> SupersededRecord? {
        guard let payload: String = row["payload"],
            let operation = try? JSONCoders.decoder.decode(
                SyncOperation.self, from: Data(payload.utf8)),
            let reason = SupersededReason(rawValue: row["reason"])
        else { return nil }

        let current: SyncRecord? = (row["current"] as String?).flatMap {
            try? JSONCoders.decoder.decode(SyncRecord.self, from: Data($0.utf8))
        }
        return SupersededRecord(
            opId: operation.opId, operation: operation, current: current,
            reason: reason, occurredAt: row["occurred_at"])
    }
}
