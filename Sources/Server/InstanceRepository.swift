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
}
