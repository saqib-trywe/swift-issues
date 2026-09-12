import Core
import Foundation
import GRDB

/// Where a queued write has got to.
public enum PendingState: String, Codable, Hashable, Sendable {
    case pending
    case inFlight
    /// Rejected by the server, kept with its error for repair or deliberate
    /// discard. Never silently dropped (ADR 0004).
    case quarantined
}

/// One row of the offline queue.
public struct PendingOperation: Sendable, Hashable, Identifiable {
    public var id: UUID { operation.opId }
    /// Queue position. Independent of the clock, so operations made in the same
    /// millisecond still have a defined order.
    public let sequence: Int64
    public let operation: SyncOperation
    public let state: PendingState
    public let problem: Problem?
    public let attemptCount: Int

    public static func == (lhs: PendingOperation, rhs: PendingOperation) -> Bool {
        lhs.sequence == rhs.sequence && lhs.operation.opId == rhs.operation.opId
            && lhs.state == rhs.state && lhs.attemptCount == rhs.attemptCount
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sequence)
        hasher.combine(operation.opId)
    }
}

extension ReplicaDatabase {

    /// Applies a write to the replica **and** enqueues it, or does neither.
    ///
    /// This single transaction is the whole reason the replica and the queue share
    /// one file (ticket 05). Its failure mode otherwise is silent divergence found
    /// days later: the user sees their edit, the server never hears about it, and
    /// nothing can tell.
    public func enqueue(_ operation: SyncOperation, at now: Date = Date()) throws {
        try writer.write { db in
            try Self.applyLocally(operation, in: db, at: now)
            try Self.insert(operation, in: db, at: now)
        }
    }

    /// The next operations that may go out, in queue order.
    ///
    /// Quarantined rows are excluded by the partial index, and anything causally
    /// downstream of one is held back — only that, which is ADR 0004's
    /// no-head-of-line-blocking requirement.
    public func readyOperations(limit: Int = 100) throws -> [PendingOperation] {
        let all = try allOperations()
        let quarantined = Set(
            all.filter { $0.state == .quarantined }.map(\.operation.opId))

        let held = SyncDependencies.blocked(
            by: quarantined, in: all.map(\.operation))

        return
            all
            .filter { $0.state == .pending }
            .filter { !held.contains($0.operation.opId) }
            .prefix(limit)
            .map { $0 }
    }

    /// Everything in the queue, including quarantined rows, in order.
    public func allOperations() throws -> [PendingOperation] {
        try reader.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM pending_operation ORDER BY sequence"
            ).compactMap(Self.pending(from:))
        }
    }

    /// Operations held back only because something they depend on is quarantined.
    ///
    /// The UI needs this separately: "waiting on a problem elsewhere" is a different
    /// thing to tell someone than "this failed".
    public func blockedOperations() throws -> [PendingOperation] {
        let all = try allOperations()
        let quarantined = Set(all.filter { $0.state == .quarantined }.map(\.operation.opId))
        let held = SyncDependencies.blocked(by: quarantined, in: all.map(\.operation))
        return all.filter { held.contains($0.operation.opId) }
    }

    /// Records a server rejection, keeping the payload so the user can repair it.
    public func quarantine(_ opId: UUID, problem: Problem?) throws {
        try writer.write { db in
            let encoded = try problem.map {
                String(decoding: try JSONCoders.encoder.encode($0), as: UTF8.self)
            }
            try db.execute(
                sql: """
                    UPDATE pending_operation
                    SET state = 'quarantined', problem = ?, attempt_count = attempt_count + 1
                    WHERE op_id = ?
                    """,
                arguments: [encoded, opId.uuidString])
        }
    }

    /// Removes an operation the server accepted.
    public func acknowledge(_ opId: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM pending_operation WHERE op_id = ?",
                arguments: [opId.uuidString])
        }
    }

    /// Merges what can be merged, in one transaction.
    ///
    /// Applied to unsent rows only: coalescing an operation the server may already
    /// have seen would change what a retry means.
    public func coalescePending() throws {
        try writer.write { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM pending_operation WHERE state = 'pending' ORDER BY sequence")
            let pending = rows.compactMap(Self.pending(from:))
            let coalesced = SyncCoalescing.coalesced(pending.map(\.operation))

            // Nothing to do, and rewriting anyway would churn the sequence numbers.
            guard
                coalesced.count != pending.count
                    || zip(coalesced, pending).contains(where: { !Self.sameBody($0, $1.operation) })
            else { return }

            try db.execute(sql: "DELETE FROM pending_operation WHERE state = 'pending'")
            for operation in coalesced {
                try Self.insert(operation, in: db, at: Date())
            }
        }
    }

    private static func sameBody(_ lhs: SyncOperation, _ rhs: SyncOperation) -> Bool {
        guard lhs.opId == rhs.opId else { return false }
        return (try? JSONCoders.encoder.encode(lhs)) == (try? JSONCoders.encoder.encode(rhs))
    }

    static func insert(_ operation: SyncOperation, in db: Database, at now: Date) throws {
        let payload = String(
            decoding: try JSONCoders.encoder.encode(operation), as: UTF8.self)
        let reference = SyncDependencies.target(of: operation)

        try db.execute(
            sql: """
                INSERT INTO pending_operation
                    (op_id, entity_type, entity_id, kind, payload, created_at, state)
                VALUES (?, ?, ?, ?, ?, ?, 'pending')
                """,
            arguments: [
                operation.opId.uuidString, reference.entity.rawValue,
                reference.id.uuidString, operation.kind.rawValue, payload, now,
            ])
    }

    static func pending(from row: Row) -> PendingOperation? {
        guard let payload: String = row["payload"],
            let operation = try? JSONCoders.decoder.decode(
                SyncOperation.self, from: Data(payload.utf8)),
            let state = PendingState(rawValue: row["state"])
        else {
            // A row this build cannot decode is skipped rather than throwing: one
            // bad row must not make the whole queue unreadable, which is exactly
            // when it matters most.
            return nil
        }

        let problem: Problem? = (row["problem"] as String?).flatMap {
            try? JSONCoders.decoder.decode(Problem.self, from: Data($0.utf8))
        }

        return PendingOperation(
            sequence: row["sequence"],
            operation: operation,
            state: state,
            problem: problem,
            attemptCount: row["attempt_count"])
    }
}
