import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import ClientStore
@testable import Server

/// The first time the sync protocol is exercised by a client rather than by the
/// server's own tests. Everything here runs against the real router.
@Suite("Sync engine")
struct SyncEngineTests {

    private func create(_ world: SyncWorld, _ title: String = "A thing") -> IssueCreate {
        IssueCreate(projectId: world.project.id, title: title)
    }

    // MARK: Push

    /// The whole point: a write made offline reaches the server when it can.
    @Test("an offline write reaches the server on push")
    func offlineWriteReachesTheServer() async throws {
        try await withSync { world in
            let device = try world.device()
            let id = Core.Issue.ID()

            try device.database.enqueue(
                .putIssue(opId: UUID(), id: id, at: Date(), body: create(world, "Made offline")))

            let summary = try await device.engine.push()

            #expect(summary.applied.count == 1)
            #expect(try world.serverIssue(id)?.title == "Made offline")
            #expect(try device.database.allOperations().isEmpty, "the queue was not drained")
        }
    }

    /// Ordering is the reason the topological sort exists: the server rejects any
    /// reference to an id it has not seen.
    @Test("a child queued before its parent still succeeds")
    func childQueuedBeforeParentStillSucceeds() async throws {
        try await withSync { world in
            let device = try world.device()
            let issue = Core.Issue.ID()
            let comment = Core.Comment.ID()

            // Deliberately the wrong way round in the queue.
            try device.database.enqueue(
                .putComment(
                    opId: UUID(), id: comment, at: Date(),
                    body: CommentCreate(issueId: issue, body: "First!")))
            try device.database.enqueue(
                .putIssue(opId: UUID(), id: issue, at: Date(), body: create(world)))

            let summary = try await device.engine.push()

            #expect(summary.applied.count == 2)
            #expect(summary.rejected.isEmpty, "ordering failed, so the server rejected a reference")
            #expect(try CommentRepository(database: world.database).find(comment) != nil)
        }
    }

    @Test("a run of patches is coalesced into one round trip")
    func runOfPatchesIsCoalesced() async throws {
        try await withSync { world in
            let device = try world.device()
            let id = Core.Issue.ID()
            try device.database.enqueue(
                .putIssue(opId: UUID(), id: id, at: Date(), body: create(world, "Original")))
            for index in 0..<20 {
                var patch = IssuePatch()
                patch.title = .set("Title \(index)")
                try device.database.enqueue(
                    .patchIssue(opId: UUID(), id: id, at: Date(), body: patch))
            }

            let summary = try await device.engine.push()

            #expect(summary.applied.count == 1, "21 operations should have become 1")
            #expect(try world.serverIssue(id)?.title == "Title 19")
        }
    }

    /// ADR 0004: a rejection is kept with its error, never silently dropped.
    @Test("a rejected operation is quarantined with its problem")
    func rejectedOperationIsQuarantined() async throws {
        try await withSync { world in
            let device = try world.device()
            // A title past the 512-character limit is refused by validation.
            var body = create(world)
            body.title = String(repeating: "a", count: 600)

            let operation = SyncOperation.putIssue(
                opId: UUID(), id: Core.Issue.ID(), at: Date(), body: body)
            try device.database.enqueue(operation)

            let summary = try await device.engine.push()

            #expect(summary.rejected == [operation.opId])
            let stored = try #require(try device.database.allOperations().first)
            #expect(stored.state == .quarantined)
            #expect(stored.problem != nil, "the user has nothing to repair from")
        }
    }

    /// The specific failure mode ADR 0004 designs against: one bad operation must
    /// not stop everything behind it.
    @Test("a rejection does not stop unrelated work going out")
    func rejectionDoesNotStopUnrelatedWork() async throws {
        try await withSync { world in
            let device = try world.device()
            var bad = create(world)
            bad.title = String(repeating: "a", count: 600)

            try device.database.enqueue(
                .putIssue(opId: UUID(), id: Core.Issue.ID(), at: Date(), body: bad))
            let goodId = Core.Issue.ID()
            try device.database.enqueue(
                .putIssue(opId: UUID(), id: goodId, at: Date(), body: create(world, "Fine")))

            let summary = try await device.engine.push()

            #expect(summary.rejected.count == 1)
            #expect(summary.applied.count == 1)
            #expect(try world.serverIssue(goodId) != nil)
        }
    }

    /// A dependent of an *already* quarantined operation is held back, and reported
    /// as held rather than as failed — they are different things to tell a user.
    ///
    /// Note what happens when both go out together instead: the server rejects each
    /// on its own merits, and the dependent is quarantined with its own error rather
    /// than blocked. Blocking matters on the retry, once something is known bad.
    @Test("a dependent of a quarantined operation is reported as blocked")
    func dependentOfQuarantinedIsBlocked() async throws {
        try await withSync { world in
            let device = try world.device()
            var bad = create(world)
            bad.title = String(repeating: "a", count: 600)
            let issue = Core.Issue.ID()

            let create = SyncOperation.putIssue(
                opId: UUID(), id: issue, at: Date(), body: bad)
            try device.database.enqueue(create)

            // The create fails and is quarantined.
            let first = try await device.engine.push()
            #expect(first.rejected == [create.opId])

            // Only now does the dependent appear, as it would if the user carried on
            // working while the failure sat in the queue.
            try device.database.enqueue(
                .putComment(
                    opId: UUID(), id: Core.Comment.ID(), at: Date(),
                    body: CommentCreate(issueId: issue, body: "Held back")))

            let second = try await device.engine.push()
            #expect(second.blocked == 1)
            #expect(second.applied.isEmpty)
            #expect(second.rejected.isEmpty, "a blocked operation was sent and failed")
        }
    }

    /// When a create and its dependent go out together for the first time, nothing
    /// is known bad yet, so both are sent and the server rejects each on its own
    /// merits. Worth pinning down: it is the behaviour, not a bug.
    @Test("an unblocked dependent sent alongside a bad create is rejected on its own merits")
    func unblockedDependentIsRejectedOnItsOwnMerits() async throws {
        try await withSync { world in
            let device = try world.device()
            var bad = create(world)
            bad.title = String(repeating: "a", count: 600)
            let issue = Core.Issue.ID()

            try device.database.enqueue(.putIssue(opId: UUID(), id: issue, at: Date(), body: bad))
            try device.database.enqueue(
                .putComment(
                    opId: UUID(), id: Core.Comment.ID(), at: Date(),
                    body: CommentCreate(issueId: issue, body: "Orphan")))

            let summary = try await device.engine.push()

            #expect(summary.rejected.count == 2)
            // Both keep their own problem, so the user is told what each failure was.
            #expect(try device.database.allOperations().allSatisfy { $0.problem != nil })
        }
    }

    /// Retrying a batch the server already saw must not write twice — that is what
    /// the opId is for.
    @Test("pushing the same operation twice is idempotent")
    func pushingTwiceIsIdempotent() async throws {
        try await withSync { world in
            let device = try world.device()
            let id = Core.Issue.ID()
            let operation = SyncOperation.putIssue(
                opId: UUID(), id: id, at: Date(), body: create(world, "Once"))

            try device.database.enqueue(operation)
            _ = try await device.engine.push()

            // Re-queue the identical operation, as a client that lost the response
            // would.
            try device.database.enqueue(operation)
            let summary = try await device.engine.push()

            #expect(summary.applied == [operation.opId])
            let count = try await world.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue")
            }
            #expect(count == 1)
        }
    }

    @Test("pushing an empty queue does nothing and says so")
    func pushingAnEmptyQueueDoesNothing() async throws {
        try await withSync { world in
            let device = try world.device()
            let summary = try await device.engine.push()
            #expect(summary.isEmpty)
        }
    }

    // MARK: Pull

    @Test("a first pull brings down everything the server has")
    func firstPullBringsDownEverything() async throws {
        try await withSync { world in
            let issue = try IssueRepository(database: world.database).create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Already there",
                    reporterId: world.owner.id))

            let device = try world.device()
            let summary = try await device.engine.pull()

            #expect(summary.changes > 0)
            let title = try await device.database.reader.read { db in
                try String.fetchOne(
                    db, sql: "SELECT title FROM issue WHERE id = ?",
                    arguments: [issue.id.rawValue.uuidString])
            }
            #expect(title == "Already there")
        }
    }

    /// The replica needs projects and users to render an issue at all, which is why
    /// they are pulled but never pushed.
    @Test("the replica receives projects and users, not just issues")
    func replicaReceivesProjectsAndUsers() async throws {
        try await withSync { world in
            let device = try world.device()
            _ = try await device.engine.pull()

            let counts = try await device.database.reader.read { db in
                (
                    projects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") ?? 0,
                    users: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user") ?? 0
                )
            }
            #expect(counts.projects == 1)
            #expect(counts.users == 1)
        }
    }

    /// A second pull with an advanced watermark must not re-deliver what has
    /// already been seen.
    @Test("a second pull with nothing new brings down nothing")
    func secondPullBringsDownNothing() async throws {
        try await withSync { world in
            let device = try world.device()
            _ = try await device.engine.pull()

            let second = try await device.engine.pull()
            #expect(second.changes == 0)
        }
    }

    @Test("the watermark advances and is remembered")
    func watermarkAdvancesAndIsRemembered() async throws {
        try await withSync { world in
            let device = try world.device()
            #expect(try device.database.watermark() == nil)

            let summary = try await device.engine.pull()
            let stored = try #require(try device.database.watermark())
            #expect(stored == summary.watermark)
        }
    }

    /// Tombstones are first-class entries; without them a delete would never
    /// propagate, and the record would live on every replica forever.
    @Test("a deletion propagates as a tombstone")
    func deletionPropagatesAsATombstone() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()
            try repository.delete(issue.id, at: Date())
            _ = try await device.engine.pull()

            let deletedAt = try await device.database.reader.read { db in
                try Date.fetchOne(
                    db, sql: "SELECT deleted_at FROM issue WHERE id = ?",
                    arguments: [issue.id.rawValue.uuidString])
            }
            #expect(deletedAt != nil)
        }
    }

    @Test("pulling walks every page")
    func pullingWalksEveryPage() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            for index in 0..<25 {
                _ = try repository.create(
                    Core.Issue.fixture(
                        key: nil, projectId: world.project.id, title: "Issue \(index)",
                        reporterId: world.owner.id))
            }

            let replica = try ReplicaDatabase.inMemory()
            let token = world.token
            let engine = SyncEngine(
                database: replica,
                client: APIClient(transport: world.transport, token: { token }),
                deviceId: "small-pages",
                pageSize: 5)

            let summary = try await engine.pull()

            #expect(summary.pages > 1, "the walk stopped after one page")
            let stored = try await replica.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue") ?? 0
            }
            #expect(stored == 25)
        }
    }

    /// The push response's watermark is the server's position *after* the batch.
    /// Adopting it would skip everything before — on a first sync, the whole
    /// history.
    @Test("pushing does not advance the watermark past unseen history")
    func pushingDoesNotSkipHistory() async throws {
        try await withSync { world in
            // History the device has never seen.
            _ = try IssueRepository(database: world.database).create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Existing",
                    reporterId: world.owner.id))

            let device = try world.device()
            try device.database.enqueue(
                .putIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: Date(), body: create(world, "Mine")))

            _ = try await device.engine.push()
            #expect(try device.database.watermark() == nil, "push adopted a watermark")

            _ = try await device.engine.pull()
            let titles = try await device.database.reader.read { db in
                try String.fetchSet(db, sql: "SELECT title FROM issue")
            }
            #expect(titles.contains("Existing"), "history before the push was skipped")
            #expect(titles.contains("Mine"))
        }
    }

    // MARK: Two devices

    /// The end-to-end claim the whole architecture rests on.
    @Test("a write on one device reaches another")
    func writeOnOneDeviceReachesAnother() async throws {
        try await withSync { world in
            let laptop = try world.device("laptop")
            let phone = try world.device("phone")
            _ = try await phone.engine.pull()

            let id = Core.Issue.ID()
            try laptop.database.enqueue(
                .putIssue(opId: UUID(), id: id, at: Date(), body: create(world, "From the laptop")))
            _ = try await laptop.engine.sync()

            _ = try await phone.engine.pull()

            let title = try await phone.database.reader.read { db in
                try String.fetchOne(
                    db, sql: "SELECT title FROM issue WHERE id = ?",
                    arguments: [id.rawValue.uuidString])
            }
            #expect(title == "From the laptop")
        }
    }

    /// Per-field last-write-wins: two devices editing different fields must both
    /// survive, which is the reason patches are field-level rather than whole
    /// records.
    @Test("concurrent edits to different fields both survive")
    func concurrentEditsToDifferentFieldsBothSurvive() async throws {
        try await withSync { world in
            let issue = try IssueRepository(database: world.database).create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Original",
                    status: .todo, priority: .none, reporterId: world.owner.id))

            let laptop = try world.device("laptop")
            let phone = try world.device("phone")
            _ = try await laptop.engine.pull()
            _ = try await phone.engine.pull()

            var titleEdit = IssuePatch()
            titleEdit.title = .set("Renamed on the laptop")
            try laptop.database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: titleEdit))

            var priorityEdit = IssuePatch()
            priorityEdit.priority = .set(.urgent)
            try phone.database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: priorityEdit))

            _ = try await laptop.engine.push()
            _ = try await phone.engine.push()

            let server = try #require(try world.serverIssue(issue.id))
            #expect(server.title == "Renamed on the laptop")
            #expect(server.priority == .urgent)
        }
    }

    /// A device's own write comes back with the server's timestamps on it, so the
    /// replica ends up holding exactly what the server holds.
    @Test("sync leaves the replica matching the server")
    func syncLeavesReplicaMatchingTheServer() async throws {
        try await withSync { world in
            let device = try world.device()
            let id = Core.Issue.ID()
            try device.database.enqueue(
                .putIssue(opId: UUID(), id: id, at: Date(), body: create(world, "Round trip")))

            _ = try await device.engine.sync()

            let server = try #require(try world.serverIssue(id))
            let local = try await device.database.reader.read { db in
                try Row.fetchOne(
                    db, sql: "SELECT * FROM issue WHERE id = ?",
                    arguments: [id.rawValue.uuidString])
            }
            let row = try #require(local)
            #expect(row["title"] == server.title)
            // The key is assigned server-side, so a matching replica must have it.
            #expect(row["key"] == server.key?.wireValue)
            #expect(row["reporter_id"] == server.reporterId.rawValue.uuidString)
        }
    }
}

/// The two paths that only exist because the protocol has to survive real
/// operational events: a record deleted under a pending edit, and a server
/// restored from backup.
@Suite("Sync recovery paths")
struct SyncRecoveryTests {

    private func create(_ world: SyncWorld, _ title: String = "A thing") -> IssueCreate {
        IssueCreate(projectId: world.project.id, title: title)
    }

    /// ADR 0005's third outcome. Without it this would be reported as a success
    /// while the user's text silently vanished.
    @Test("an edit to something deleted elsewhere comes back superseded")
    func editToSomethingDeletedComesBackSuperseded() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()

            // Edited here while it is deleted there.
            var patch = IssuePatch()
            patch.title = .set("My careful rewording")
            let operation = SyncOperation.patchIssue(
                opId: UUID(), id: issue.id, at: Date(), body: patch)
            try device.database.enqueue(operation)
            try repository.delete(issue.id, at: Date())

            let summary = try await device.engine.push()

            #expect(summary.superseded.count == 1)
            #expect(summary.rejected.isEmpty)
            let lost = try #require(summary.superseded.first)
            #expect(lost.opId == operation.opId)
        }
    }

    /// Quarantine means repair and retry, and there is nothing left to retry
    /// against — leaving it pending would produce an operation that fails forever.
    @Test("a superseded operation leaves the queue rather than being quarantined")
    func supersededOperationLeavesTheQueue() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()
            var patch = IssuePatch()
            patch.title = .set("Lost work")
            try device.database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))
            try repository.delete(issue.id, at: Date())

            _ = try await device.engine.push()

            #expect(try device.database.allOperations().isEmpty)
        }
    }

    /// The user's text has to be recoverable, or "superseded" is just a polite way
    /// of losing their work.
    @Test("the superseded operation is handed back with its payload intact")
    func supersededOperationIsHandedBackIntact() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()
            var patch = IssuePatch()
            patch.title = .set("Two hours of careful editing")
            try device.database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))
            try repository.delete(issue.id, at: Date())

            let summary = try await device.engine.push()
            let lost = try #require(summary.superseded.first)

            guard case .patchIssue(_, _, _, let body) = lost.operation else {
                Issue.record("the payload came back as the wrong kind")
                return
            }
            #expect(body.title == .set("Two hours of careful editing"))
            // And what won, so the UI can show it alongside.
            #expect(lost.current != nil)
        }
    }

    /// Ticket 09: a restore mints a new epoch, and a client holding the old one must
    /// resync rather than being silently cut off forever.
    @Test("a superseded epoch forces a full resync")
    func supersededEpochForcesAFullResync() async throws {
        try await withSync { world in
            _ = try IssueRepository(database: world.database).create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Before the restore",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()
            let before = try #require(try device.database.watermark())

            // A restore, as ticket 09 describes it.
            try await world.database.writer.write { db in
                try db.execute(
                    sql: "UPDATE instance SET epoch = ? WHERE id = 1",
                    arguments: ["restored-\(UUID().uuidString)"])
            }

            let summary = try await device.engine.pull()

            #expect(summary.resynced, "the client did not notice the epoch change")
            let after = try #require(try device.database.watermark())
            #expect(!after.hasSameEpoch(as: before))
            // And the replica is whole again rather than empty.
            let titles = try await device.database.reader.read { db in
                try String.fetchSet(db, sql: "SELECT title FROM issue")
            }
            #expect(titles.contains("Before the restore"))
        }
    }

    /// The pending queue is unsent user work. Losing it to a server-side
    /// operational event is exactly the silent data loss ADR 0004 forbids.
    @Test("a full resync keeps the pending queue")
    func fullResyncKeepsThePendingQueue() async throws {
        try await withSync { world in
            let device = try world.device()
            _ = try await device.engine.pull()

            let operation = SyncOperation.putIssue(
                opId: UUID(), id: Core.Issue.ID(), at: Date(),
                body: create(world, "Written while offline"))
            try device.database.enqueue(operation)

            try await world.database.writer.write { db in
                try db.execute(
                    sql: "UPDATE instance SET epoch = ? WHERE id = 1",
                    arguments: ["restored-\(UUID().uuidString)"])
            }

            let summary = try await device.engine.pull()

            #expect(summary.resynced)
            #expect(
                try device.database.allOperations().map(\.operation.opId) == [operation.opId],
                "a server restore threw away unsent user work")
        }
    }

    /// And it must still go out afterwards, or it is preserved in name only.
    @Test("work kept through a resync still reaches the server")
    func workKeptThroughAResyncStillReachesTheServer() async throws {
        try await withSync { world in
            let device = try world.device()
            _ = try await device.engine.pull()

            let id = Core.Issue.ID()
            try device.database.enqueue(
                .putIssue(opId: UUID(), id: id, at: Date(), body: create(world, "Survived")))

            try await world.database.writer.write { db in
                try db.execute(
                    sql: "UPDATE instance SET epoch = ? WHERE id = 1",
                    arguments: ["restored-\(UUID().uuidString)"])
            }

            _ = try await device.engine.pull()
            _ = try await device.engine.push()

            #expect(try world.serverIssue(id)?.title == "Survived")
        }
    }
}
