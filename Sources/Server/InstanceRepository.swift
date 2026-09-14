import Core
import Foundation
import GRDB

/// The single row describing this Instance.
struct InstanceRepository: Sendable {
    let database: AppDatabase

    func name() throws -> String {
        try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM instance WHERE id = 1") ?? "Issues"
        }
    }

    /// The watermark epoch. A restore mints a new one, which is what stops a
    /// client resuming against a rewound sequence (ticket 09).
    func epoch() throws -> String {
        try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT epoch FROM instance WHERE id = 1") ?? ""
        }
    }

    /// Mints a new epoch, invalidating every watermark clients are holding.
    ///
    /// Only a restore does this. Every client is then told to full-resync, which is
    /// disruptive — and is the entire point: the alternative is each of them
    /// believing a rewound sequence is current and diverging in silence.
    @discardableResult
    func renewEpoch() throws -> String {
        let epoch = UUIDv7.generate().uuidString
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE instance SET epoch = ? WHERE id = 1", arguments: [epoch])
        }
        return epoch
    }
}
