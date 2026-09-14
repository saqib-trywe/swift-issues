import Core
import Foundation
import GRDB

/// Backup, restore, and the safety copy taken before a migration (ticket 09).
///
/// All of it is operator-facing and all of it can destroy an issue tracker, so
/// every destructive step here validates before it touches anything and moves the
/// old data aside rather than deleting it.
public enum Maintenance {

    // MARK: What an operator gets back

    public struct BackupReport: Sendable, Equatable {
        public let url: URL
        public let byteCount: Int
    }

    /// Enough to recognise a backup file without restoring it.
    public struct DatabaseSummary: Sendable, Equatable {
        public let epoch: String
        public let userCount: Int
        public let projectCount: Int
        public let issueCount: Int
        /// False when the file predates this binary, which means restoring it will
        /// migrate it forward. Worth saying out loud before it happens.
        public let isCurrentSchema: Bool
    }

    public struct RestoreReport: Sendable, Equatable {
        /// Absent when the restore landed on an empty path.
        public let previousEpoch: String?
        /// Always new. Ticket 09: a restore rewinds the sequence, so the epoch has
        /// to change or every client silently diverges instead of resyncing.
        public let epoch: String
        /// Where the data that used to be there went.
        public let movedAside: URL?
        public let summary: DatabaseSummary
    }

    /// Every refusal an operator can hit, each one saying what to do instead.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case sourceMissing(URL)
        case destinationExists(URL)
        case targetExists(URL)
        case notAnIssuesDatabase(URL)
        case fromANewerServer(URL)
        case inUse(URL)

        public var description: String {
            switch self {
            case .sourceMissing(let url):
                "There is no file at \(url.path)."
            case .destinationExists(let url):
                "\(url.path) already exists. Back up to a new path rather than over an old backup."
            case .targetExists(let url):
                "\(url.path) already holds a database. Pass --force to replace it; the current data is moved aside, not deleted."
            case .notAnIssuesDatabase(let url):
                "\(url.path) is not an Issues database."
            case .fromANewerServer(let url):
                "\(url.path) was written by a newer issues-server than this one. Upgrade the binary before restoring it."
            case .inUse(let url):
                "\(url.path) is open by another process — the server is probably running. Stop it first: launchctl bootout gui/$UID/co.trywe.issues.server"
            }
        }
    }

    // MARK: Backup

    /// SQLite's online backup: one consistent file, taken while the server runs.
    ///
    /// `cp` of the data directory is **not** equivalent and is unsupported. A live
    /// WAL database holds committed transactions in the `-wal` file, so copying the
    /// three files non-atomically — or copying only `issues.sqlite` — produces
    /// something corrupt or silently stale. It appears to work right up until the
    /// day it is needed. This is why ADR 0010's original "backup is copying a file"
    /// was corrected by ticket 09.
    ///
    /// Refuses an existing destination rather than overwriting: the file most likely
    /// to be sitting at a backup path is an earlier backup.
    @discardableResult
    public static func backup(databaseAt source: URL, to destination: URL) throws -> BackupReport {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { throw Failure.sourceMissing(source) }
        guard !manager.fileExists(atPath: destination.path) else {
            throw Failure.destinationExists(destination)
        }

        try consolidate(from: source, to: destination)

        let attributes = try? manager.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? Int) ?? 0
        return BackupReport(url: destination, byteCount: size)
    }

    /// Writes everything committed to `source` into a single new file.
    ///
    /// `VACUUM INTO` rather than a file copy, and for the same reason everywhere it
    /// is used: a live database keeps its most recent commits in the `-wal`, so
    /// copying the main file alone yields something stale or corrupt. A test caught
    /// this in `restore`, where copying a source that happened to have an open WAL
    /// produced a restored database with none of the data in it.
    ///
    /// Deliberately *not* `AppDatabase.open`: that migrates, and neither taking a
    /// backup nor reading one is a moment for a schema change to happen as a side
    /// effect.
    static func consolidate(from source: URL, to destination: URL) throws {
        do {
            let pool = try DatabasePool(path: source.path)
            defer { try? pool.close() }
            try pool.vacuum(into: destination.path)
        } catch {
            throw Failure.notAnIssuesDatabase(source)
        }
    }

    // MARK: Inspection

    /// Reads a file's identity without changing it.
    ///
    /// Read-only on purpose: inspecting a backup must never migrate it, or the act
    /// of looking would consume the thing being looked at.
    public static func inspect(_ url: URL) throws -> DatabaseSummary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.sourceMissing(url)
        }

        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration) else {
            throw Failure.notAnIssuesDatabase(url)
        }
        defer { try? queue.close() }

        return try queue.read { db in
            // A path only proves itself a database on first read, so anything that
            // is not one surfaces here rather than at open.
            let looksRight =
                (try? db.tableExists("instance")) == true
                && (try? db.tableExists("issue")) == true
            guard looksRight else { throw Failure.notAnIssuesDatabase(url) }

            // A database carrying migrations this binary has never heard of came
            // from a newer server. Opening it would migrate nothing and then fail
            // somewhere less obvious.
            if (try? AppDatabase.migrator.hasBeenSuperseded(db)) == true {
                throw Failure.fromANewerServer(url)
            }

            guard
                let epoch = try String.fetchOne(db, sql: "SELECT epoch FROM instance WHERE id = 1")
            else { throw Failure.notAnIssuesDatabase(url) }

            func count(_ sql: String) -> Int { ((try? Int.fetchOne(db, sql: sql)) ?? 0) ?? 0 }

            return DatabaseSummary(
                epoch: epoch,
                userCount: count("SELECT COUNT(*) FROM user"),
                projectCount: count("SELECT COUNT(*) FROM project"),
                issueCount: count("SELECT COUNT(*) FROM issue WHERE deleted_at IS NULL"),
                isCurrentSchema: (try? AppDatabase.migrator.hasCompletedMigrations(db)) == true)
        }
    }

    /// Whether another connection has this database open.
    ///
    /// Exclusive locking mode is the question asked: in WAL mode every open
    /// connection holds a shared lock for as long as it lives, so taking that lock
    /// exclusively fails precisely when somebody else is attached. Checking for a
    /// `-wal` file instead would be wrong in both directions — it survives an
    /// unclean shutdown, and it is absent while a fresh connection is merely open.
    ///
    /// Only `SQLITE_BUSY` counts. Any other error means something else is wrong with
    /// the file, and reporting that as "the server is running" would send an
    /// operator to stop a service that is already stopped.
    public static func isInUse(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let queue = try DatabaseQueue(path: url.path)
            defer { try? queue.close() }
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA locking_mode = EXCLUSIVE")
                try db.execute(sql: "BEGIN IMMEDIATE")
                try db.execute(sql: "ROLLBACK")
                try db.execute(sql: "PRAGMA locking_mode = NORMAL")
            }
            return false
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            return true
        } catch {
            return false
        }
    }

    // MARK: Restore

    /// Replaces the live database with a backup, and mints a new instance epoch.
    ///
    /// The epoch is the whole reason this is not `cp`. The pull watermark is a
    /// monotonic sequence, so restoring an older file rewinds the counter and
    /// numbers get reused for different changes: a client holding 900 against a
    /// server restored to 400 asks for `> 900`, receives nothing, and believes it is
    /// current — forever, with no error anywhere. A new epoch turns that silent
    /// permanent divergence into one full resync (ticket 08's escape hatch, which
    /// never clears the pending queue).
    ///
    /// Nothing is deleted. The database being replaced is moved aside with its
    /// sidecars, because "I restored the wrong backup" must stay recoverable.
    @discardableResult
    public static func restore(from source: URL, to target: URL, force: Bool) throws
        -> RestoreReport
    {
        // Validate first, always. A source that turns out to be unreadable must not
        // have cost the operator the database it was going to replace.
        let summary = try inspect(source)

        let manager = FileManager.default
        let targetExists = manager.fileExists(atPath: target.path)
        var previousEpoch: String?
        var movedAside: URL?

        if targetExists {
            guard force else { throw Failure.targetExists(target) }
            guard !isInUse(at: target) else { throw Failure.inUse(target) }
            previousEpoch = try? inspect(target).epoch
            movedAside = try moveAside(target)
        }

        try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try consolidate(from: source, to: target)

        // Opening migrates, so an older backup is carried forward rather than
        // left for the next start to discover.
        let database = try AppDatabase.open(at: target)
        let epoch = try InstanceRepository(database: database).renewEpoch()

        return RestoreReport(
            previousEpoch: previousEpoch, epoch: epoch, movedAside: movedAside,
            summary: summary)
    }

    /// Renames a database and its sidecars out of the way, keeping the three
    /// together.
    ///
    /// A rename rather than a copy: it is atomic, it costs nothing on a large
    /// database, and — unlike `VACUUM INTO` — it still works when the file being
    /// set aside is corrupt, which is exactly when a restore is being run.
    static func moveAside(_ url: URL, now: Date = Date()) throws -> URL {
        let stamp = Self.stampFormatter.string(from: now)
        let base = url.deletingLastPathComponent()
            .appending(path: url.lastPathComponent + ".superseded-" + stamp)
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: from.path) else { continue }
            try manager.moveItem(at: from, to: URL(fileURLWithPath: base.path + suffix))
        }
        return base
    }

    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: The automatic pre-migration backup

    /// Where a pre-migration safety copy lives. Beside the database, so an operator
    /// finding one knows immediately what it belongs to.
    public static func preMigrationBackupURL(for database: URL) -> URL {
        URL(fileURLWithPath: database.path + ".pre-migration")
    }

    /// Opens the server's database, copying it first if this binary is about to
    /// migrate it.
    ///
    /// Ticket 09 auto-migrates on startup, which is right for single-tenant software
    /// with no fleet to coordinate — and it is also the one thing here that could
    /// destroy data with no recovery path. The copy makes a failed migration
    /// annoying rather than terminal.
    ///
    /// Retained until the next successful start, as specified: the previous copy is
    /// removed on the way in, so at most one exists and it is always the one for the
    /// schema currently running.
    public static func openForService(at url: URL) throws -> (
        database: AppDatabase, preMigrationBackup: URL?
    ) {
        let backupURL = preMigrationBackupURL(for: url)
        try? FileManager.default.removeItem(at: backupURL)

        var taken: URL?
        if try migrationIsPending(at: url) {
            try backup(databaseAt: url, to: backupURL)
            taken = backupURL
        }
        return (try AppDatabase.open(at: url), taken)
    }

    /// Whether opening this database would change its schema.
    ///
    /// A file that does not exist yet is a fresh install, not a migration: there is
    /// nothing to lose and nothing to copy.
    static func migrationIsPending(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let pool = try DatabasePool(path: url.path)
        defer { try? pool.close() }
        return try pool.read { db in
            guard try db.tableExists("grdb_migrations") else { return false }
            return try !AppDatabase.migrator.hasCompletedMigrations(db)
        }
    }
}
