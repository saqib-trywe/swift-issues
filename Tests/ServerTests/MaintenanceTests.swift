import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Server

/// Ticket 09's operator commands. Every one of these can destroy an issue tracker,
/// so the refusals matter as much as the successes.
@Suite("Backup and restore")
struct MaintenanceTests {

    // MARK: Scratch space

    /// A directory of its own per test, so nothing here can reach a real install.
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "issues-maintenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A populated database at a path, closed before it is returned so nothing holds
    /// a lock the test did not ask for.
    @discardableResult
    private func seed(at url: URL, email: String = "user@example.com") throws -> String {
        let database = try AppDatabase.open(at: url)
        try UserRepository(database: database).save(.fixture(email: email))
        try ProjectRepository(database: database).save(.fixture())
        let epoch = try InstanceRepository(database: database).epoch()
        try database.writer.close()
        return epoch
    }

    // MARK: Backup

    @Test("a backup holds the data that was in the database")
    func backupHoldsTheData() throws {
        let directory = try scratch()
        let source = directory.appending(path: "issues.sqlite")
        try seed(at: source, email: "backed-up@example.com")
        let destination = directory.appending(path: "issues-backup.sqlite")

        let report = try Maintenance.backup(databaseAt: source, to: destination)

        #expect(report.byteCount > 0)
        let summary = try Maintenance.inspect(destination)
        #expect(summary.userCount == 1)
        #expect(summary.projectCount == 1)
        #expect(summary.isCurrentSchema)
    }

    /// A live WAL database keeps committed transactions in its `-wal` file, which is
    /// why `cp` is unsupported. The backup must include what was written through a
    /// connection that is still open.
    @Test("a backup taken while the database is open includes recent writes")
    func backupIsOnline() throws {
        let directory = try scratch()
        let source = directory.appending(path: "issues.sqlite")
        try seed(at: source)

        let live = try AppDatabase.open(at: source)
        try UserRepository(database: live).save(.fixture(email: "written-while-open@example.com"))

        let destination = directory.appending(path: "hot.sqlite")
        try Maintenance.backup(databaseAt: source, to: destination)

        #expect(try Maintenance.inspect(destination).userCount == 2)
        try live.writer.close()
    }

    /// The file most likely to be sitting at a backup path is an earlier backup.
    @Test("a backup refuses to overwrite an existing file")
    func backupRefusesToOverwrite() throws {
        let directory = try scratch()
        let source = directory.appending(path: "issues.sqlite")
        try seed(at: source)
        let destination = directory.appending(path: "taken.sqlite")
        try Data("earlier backup".utf8).write(to: destination)

        #expect(throws: Maintenance.Failure.destinationExists(destination)) {
            try Maintenance.backup(databaseAt: source, to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("earlier backup".utf8))
    }

    @Test("backing up a path with nothing at it says so")
    func backupOfMissingSource() throws {
        let directory = try scratch()
        let missing = directory.appending(path: "absent.sqlite")

        #expect(throws: Maintenance.Failure.sourceMissing(missing)) {
            try Maintenance.backup(
                databaseAt: missing, to: directory.appending(path: "out.sqlite"))
        }
    }

    @Test("backing up something that is not a database says so")
    func backupOfJunk() throws {
        let directory = try scratch()
        let junk = directory.appending(path: "notes.txt")
        try Data("this is not a database".utf8).write(to: junk)

        #expect(throws: Maintenance.Failure.notAnIssuesDatabase(junk)) {
            try Maintenance.backup(databaseAt: junk, to: directory.appending(path: "out.sqlite"))
        }
    }

    // MARK: Inspection

    @Test("inspecting reports the epoch and what is inside")
    func inspectReportsContents() throws {
        let directory = try scratch()
        let source = directory.appending(path: "issues.sqlite")
        let epoch = try seed(at: source)

        let summary = try Maintenance.inspect(source)

        #expect(summary.epoch == epoch)
        #expect(!summary.epoch.isEmpty)
        #expect(summary.userCount == 1)
        #expect(summary.issueCount == 0)
    }

    @Test("inspecting does not migrate what it inspects")
    func inspectDoesNotMigrate() throws {
        let directory = try scratch()
        let old = directory.appending(path: "old.sqlite")
        try Self.makeOlderSchema(at: old)

        #expect(try Maintenance.inspect(old).isCurrentSchema == false)
        // Still old: looking at a backup must not consume it.
        #expect(try Maintenance.inspect(old).isCurrentSchema == false)
    }

    @Test(
        "inspecting something that is not an Issues database says so",
        arguments: ["junk", "empty"])
    func inspectRejectsNonIssuesFiles(kind: String) throws {
        let directory = try scratch()
        let url = directory.appending(path: "\(kind).sqlite")
        if kind == "junk" {
            try Data("not a database".utf8).write(to: url)
        } else {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { try $0.execute(sql: "CREATE TABLE unrelated (x)") }
            try queue.close()
        }

        #expect(throws: Maintenance.Failure.notAnIssuesDatabase(url)) {
            try Maintenance.inspect(url)
        }
    }

    /// A database carrying migrations this binary has never heard of came from a
    /// newer server. Restoring it would appear to work and then fail somewhere far
    /// less obvious than here.
    @Test("a database from a newer server is refused")
    func newerDatabaseIsRefused() throws {
        let directory = try scratch()
        let url = directory.appending(path: "future.sqlite")
        try seed(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write {
            try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-the-future')")
        }
        try queue.close()

        #expect(throws: Maintenance.Failure.fromANewerServer(url)) {
            try Maintenance.inspect(url)
        }
    }

    @Test("inspecting a path with nothing at it says so")
    func inspectMissing() throws {
        let missing = try scratch().appending(path: "absent.sqlite")
        #expect(throws: Maintenance.Failure.sourceMissing(missing)) {
            try Maintenance.inspect(missing)
        }
    }

    // MARK: In use

    @Test("a database nobody has open is not in use")
    func idleDatabaseIsNotInUse() throws {
        let url = try scratch().appending(path: "issues.sqlite")
        try seed(at: url)
        #expect(!Maintenance.isInUse(at: url))
    }

    @Test("a database with a live connection is in use")
    func openDatabaseIsInUse() throws {
        let url = try scratch().appending(path: "issues.sqlite")
        try seed(at: url)

        let live = try AppDatabase.open(at: url)
        #expect(Maintenance.isInUse(at: url))
        try live.writer.close()

        #expect(!Maintenance.isInUse(at: url))
    }

    /// A path with nothing at it cannot be busy, and saying otherwise would send an
    /// operator to stop a server that is not running.
    @Test("a path with nothing at it is not in use")
    func missingPathIsNotInUse() throws {
        #expect(!Maintenance.isInUse(at: try scratch().appending(path: "absent.sqlite")))
    }

    // MARK: Restore

    /// The load-bearing one. Restoring rewinds the sequence, so without a new epoch
    /// a client holding a high watermark asks for changes beyond it, gets nothing,
    /// and believes it is current — permanently, with no error anywhere.
    @Test("a restore mints a new epoch")
    func restoreMintsANewEpoch() throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        let backedUpEpoch = try seed(at: backup)
        let target = directory.appending(path: "live.sqlite")

        let report = try Maintenance.restore(from: backup, to: target, force: false)

        #expect(report.epoch != backedUpEpoch)
        #expect(!report.epoch.isEmpty)
        #expect(try Maintenance.inspect(target).epoch == report.epoch)
        // The backup itself is untouched, so it can be restored again.
        #expect(try Maintenance.inspect(backup).epoch == backedUpEpoch)
    }

    @Test("a restore brings the data with it")
    func restoreBringsTheData() throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        try seed(at: backup, email: "restored@example.com")
        let target = directory.appending(path: "live.sqlite")

        let report = try Maintenance.restore(from: backup, to: target, force: false)

        #expect(report.summary.userCount == 1)
        #expect(report.previousEpoch == nil)
        #expect(report.movedAside == nil)
        let restored = try AppDatabase.open(at: target)
        let emails = try restored.reader.read { try String.fetchAll($0, sql: "SELECT email FROM user") }
        #expect(emails == ["restored@example.com"])
        try restored.writer.close()
    }

    @Test("a restore over an existing database is refused without --force")
    func restoreRefusesWithoutForce() throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        try seed(at: backup, email: "from-backup@example.com")
        let target = directory.appending(path: "live.sqlite")
        try seed(at: target, email: "already-here@example.com")

        #expect(throws: Maintenance.Failure.targetExists(target)) {
            try Maintenance.restore(from: backup, to: target, force: false)
        }
        #expect(try Maintenance.inspect(target).userCount == 1)
        let live = try AppDatabase.open(at: target)
        let emails = try live.reader.read { try String.fetchAll($0, sql: "SELECT email FROM user") }
        #expect(emails == ["already-here@example.com"])
        try live.writer.close()
    }

    /// "I restored the wrong backup" has to stay recoverable, so the data being
    /// replaced is moved aside rather than deleted.
    @Test("a forced restore moves the old database aside rather than deleting it")
    func forcedRestoreKeepsTheOldData() throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        try seed(at: backup, email: "from-backup@example.com")
        let target = directory.appending(path: "live.sqlite")
        let liveEpoch = try seed(at: target, email: "already-here@example.com")

        let report = try Maintenance.restore(from: backup, to: target, force: true)

        #expect(report.previousEpoch == liveEpoch)
        let aside = try #require(report.movedAside)
        #expect(FileManager.default.fileExists(atPath: aside.path))

        let recovered = try AppDatabase.open(at: aside)
        let emails = try recovered.reader.read {
            try String.fetchAll($0, sql: "SELECT email FROM user")
        }
        #expect(emails == ["already-here@example.com"])
        try recovered.writer.close()

        let now = try AppDatabase.open(at: target)
        let live = try now.reader.read { try String.fetchAll($0, sql: "SELECT email FROM user") }
        #expect(live == ["from-backup@example.com"])
        try now.writer.close()
    }

    /// Leaving the old `-wal` beside a restored file is how a restore corrupts a
    /// database: SQLite would replay frames belonging to data that is no longer
    /// there.
    @Test("a forced restore leaves no stale sidecar beside the new database")
    func forcedRestoreClearsSidecars() throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        try seed(at: backup)
        let target = directory.appending(path: "live.sqlite")
        try seed(at: target, email: "old@example.com")
        // A connection that was not closed cleanly leaves both sidecars behind.
        try Data("stale".utf8).write(to: URL(fileURLWithPath: target.path + "-wal"))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: target.path + "-shm"))

        let report = try Maintenance.restore(from: backup, to: target, force: true)

        // The sidecars went with the database they belonged to, rather than being
        // left beside a file whose contents they no longer describe.
        let aside = try #require(report.movedAside)
        #expect(FileManager.default.fileExists(atPath: aside.path + "-wal"))
        let restored = try AppDatabase.open(at: target)
        let emails = try restored.reader.read {
            try String.fetchAll($0, sql: "SELECT email FROM user")
        }
        #expect(emails == ["user@example.com"])
        try restored.writer.close()
    }

    @Test("a restore over a running server is refused")
    func restoreRefusesWhileInUse() throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        try seed(at: backup)
        let target = directory.appending(path: "live.sqlite")
        try seed(at: target, email: "serving@example.com")

        let running = try AppDatabase.open(at: target)
        #expect(throws: Maintenance.Failure.inUse(target)) {
            try Maintenance.restore(from: backup, to: target, force: true)
        }
        try running.writer.close()

        #expect(try Maintenance.inspect(target).userCount == 1)
    }

    /// Validation comes first, always: an unreadable source must not have cost the
    /// operator the database it was going to replace.
    @Test("an unreadable backup leaves the existing database alone")
    func invalidSourceLeavesTheTargetAlone() throws {
        let directory = try scratch()
        let junk = directory.appending(path: "not-a-backup.sqlite")
        try Data("nonsense".utf8).write(to: junk)
        let target = directory.appending(path: "live.sqlite")
        let epoch = try seed(at: target, email: "untouched@example.com")

        #expect(throws: Maintenance.Failure.notAnIssuesDatabase(junk)) {
            try Maintenance.restore(from: junk, to: target, force: true)
        }

        let summary = try Maintenance.inspect(target)
        #expect(summary.epoch == epoch)
        #expect(summary.userCount == 1)
    }

    /// A backup older than the running binary is carried forward on restore, rather
    /// than left for the next start to discover.
    @Test("restoring an older backup migrates it")
    func restoreMigratesAnOlderBackup() throws {
        let directory = try scratch()
        let old = directory.appending(path: "old.sqlite")
        try Self.makeOlderSchema(at: old)
        #expect(try Maintenance.inspect(old).isCurrentSchema == false)

        let target = directory.appending(path: "live.sqlite")
        let report = try Maintenance.restore(from: old, to: target, force: false)

        // Reported as it was found, migrated as it now is.
        #expect(report.summary.isCurrentSchema == false)
        #expect(try Maintenance.inspect(target).isCurrentSchema)
    }

    // MARK: The automatic pre-migration backup

    @Test("a start with a migration to run copies the database first")
    func migrationTakesABackup() throws {
        let directory = try scratch()
        let url = directory.appending(path: "issues.sqlite")
        try Self.makeOlderSchema(at: url)

        let (database, backup) = try Maintenance.openForService(at: url)
        defer { try? database.writer.close() }

        let taken = try #require(backup)
        #expect(taken == Maintenance.preMigrationBackupURL(for: url))
        // The copy predates the migration; the live database has had it applied.
        #expect(try Maintenance.inspect(taken).isCurrentSchema == false)
        let migrated = try database.reader.read { try $0.columns(in: "session").map(\.name) }
        #expect(migrated.contains("id"))
    }

    @Test("a start with nothing to migrate takes no backup")
    func noMigrationNoBackup() throws {
        let directory = try scratch()
        let url = directory.appending(path: "issues.sqlite")
        try seed(at: url)

        let (database, backup) = try Maintenance.openForService(at: url)
        defer { try? database.writer.close() }

        #expect(backup == nil)
        #expect(!FileManager.default.fileExists(atPath: Maintenance.preMigrationBackupURL(for: url).path))
    }

    /// Ticket 09 retains the copy until the next successful start, so at most one
    /// exists and it always belongs to the schema currently running.
    @Test("the previous start's backup is cleared")
    func previousBackupIsCleared() throws {
        let directory = try scratch()
        let url = directory.appending(path: "issues.sqlite")
        try seed(at: url)
        let stale = Maintenance.preMigrationBackupURL(for: url)
        try Data("from an older start".utf8).write(to: stale)

        let (database, _) = try Maintenance.openForService(at: url)
        defer { try? database.writer.close() }

        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("a first run has nothing to back up")
    func firstRunTakesNoBackup() throws {
        let url = try scratch().appending(path: "issues.sqlite")

        #expect(try Maintenance.migrationIsPending(at: url) == false)
        let (database, backup) = try Maintenance.openForService(at: url)
        defer { try? database.writer.close() }
        #expect(backup == nil)
        #expect(try Maintenance.inspect(url).isCurrentSchema)
    }

    /// The tables can be right and the file still not be an instance: a database
    /// whose single instance row is gone has no epoch, and every watermark it could
    /// hand out would be meaningless.
    @Test("a database with no instance row is not an Issues database")
    func missingInstanceRow() throws {
        let url = try scratch().appending(path: "hollow.sqlite")
        try seed(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: "DELETE FROM instance") }
        try queue.close()

        #expect(throws: Maintenance.Failure.notAnIssuesDatabase(url)) {
            try Maintenance.inspect(url)
        }
    }

    /// A file that is a database but has never been migrated has no migrations to
    /// complete, so there is nothing to copy before starting.
    @Test("an unmigrated file is not treated as a pending migration")
    func unmigratedFileHasNothingPending() throws {
        let url = try scratch().appending(path: "blank.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE unrelated (x)") }
        try queue.close()

        #expect(try Maintenance.migrationIsPending(at: url) == false)
    }

    // MARK: Helpers

    /// A database as an older build of this binary would have left it: migrated up
    /// to v4, before sessions had public ids.
    static func makeOlderSchema(at url: URL) throws {
        let pool = try DatabasePool(path: url.path)
        try AppDatabase.migrator.migrate(pool, upTo: "v4-bootstrap-token")
        try pool.close()
    }
}
