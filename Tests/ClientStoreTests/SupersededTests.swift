import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import ClientStore
@testable import Server

/// Ticket 05's treatment of work that can never be sent.
///
/// Quarantine means repair and retry, and there is nothing left to retry against.
/// The user gets their text handed back instead — and it has to survive the moment
/// it happens, or a summary nothing was watching is the same as losing it.
@Suite("Superseded writes")
struct SupersededTests {

    private func create(_ world: SyncWorld, _ title: String = "A thing") -> IssueCreate {
        IssueCreate(projectId: world.project.id, title: title)
    }

    /// The push half: the server says superseded, and the text is kept.
    @Test("a superseded push is recorded, not just returned")
    func supersededPushIsRecorded() async throws {
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
            let operation = SyncOperation.patchIssue(
                opId: UUID(), id: issue.id, at: Date(), body: patch)
            try device.database.enqueue(operation)
            try repository.delete(issue.id, at: Date())

            _ = try await device.engine.push()

            let kept = try device.database.supersededWrites()
            #expect(kept.count == 1)
            let record = try #require(kept.first)
            #expect(record.opId == operation.opId)
            #expect(record.reason == .rejectedByServer)

            guard case .patchIssue(_, _, _, let body) = record.operation else {
                Issue.record("the payload came back as the wrong kind")
                return
            }
            #expect(body.title == .set("Two hours of careful editing"))
            // And what won, so the UI can show it alongside.
            #expect(record.current != nil)
        }
    }

    /// The pull half, which ticket 05 asks for explicitly: the user learns as soon
    /// as the client knows, rather than at the next push.
    @Test("a tombstone arriving on a pull drops the pending edit and keeps its text")
    func tombstoneOnPullDropsPendingEdit() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()

            var patch = IssuePatch()
            patch.title = .set("My unsent rewording")
            let operation = SyncOperation.patchIssue(
                opId: UUID(), id: issue.id, at: Date(), body: patch)
            try device.database.enqueue(operation)

            // Deleted elsewhere, and the tombstone arrives before this device pushes.
            try repository.delete(issue.id, at: Date())
            let summary = try await device.engine.pull()

            #expect(summary.superseded.count == 1)
            #expect(summary.superseded.first?.reason == .deletedElsewhere)
            #expect(
                try device.database.allOperations().isEmpty,
                "an operation that can never succeed was left in the queue")
            #expect(try device.database.supersededWrites().count == 1)
        }
    }

    /// Transitive, which falls straight out of the derived dependency rule: a
    /// pending comment on a deleted issue can never be sent either.
    @Test("work depending on a deleted entity is dropped with it")
    func dependentWorkIsDroppedToo() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()
            try device.database.enqueue(
                .putComment(
                    opId: UUID(), id: Core.Comment.ID(), at: Date(),
                    body: CommentCreate(issueId: issue.id, body: "A comment nobody will read")))

            try repository.delete(issue.id, at: Date())
            let summary = try await device.engine.pull()

            #expect(summary.superseded.count == 1)
            #expect(summary.superseded.first?.reason == .deletedElsewhere)
            #expect(try device.database.allOperations().isEmpty)
        }
    }

    /// A chain: the comment names the issue, and an edit to the comment names the
    /// comment. Both go when the issue does.
    @Test("a chain of dependent work is dropped transitively")
    func chainOfDependentWorkIsDropped() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()

            let comment = Core.Comment.ID()
            try device.database.enqueue(
                .putComment(
                    opId: UUID(), id: comment, at: Date(),
                    body: CommentCreate(issueId: issue.id, body: "First")))
            var edit = CommentPatch()
            edit.body = .set("Second thoughts")
            try device.database.enqueue(
                .patchComment(opId: UUID(), id: comment, at: Date(), body: edit))

            try repository.delete(issue.id, at: Date())
            let summary = try await device.engine.pull()

            #expect(summary.superseded.count == 2)
            #expect(summary.superseded.contains { $0.reason == .dependencyRemoved })
            #expect(try device.database.allOperations().isEmpty)
        }
    }

    /// The specific failure this must not cause: unrelated work carrying on.
    @Test("a tombstone does not disturb unrelated pending work")
    func tombstoneDoesNotDisturbUnrelatedWork() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let doomed = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()

            var patch = IssuePatch()
            patch.title = .set("Lost")
            try device.database.enqueue(
                .patchIssue(opId: UUID(), id: doomed.id, at: Date(), body: patch))
            let survivor = SyncOperation.putIssue(
                opId: UUID(), id: Core.Issue.ID(), at: Date(), body: create(world, "Unrelated"))
            try device.database.enqueue(survivor)

            try repository.delete(doomed.id, at: Date())
            _ = try await device.engine.pull()

            #expect(
                try device.database.allOperations().map(\.operation.opId) == [survivor.opId])

            // And it still goes out.
            let pushed = try await device.engine.push()
            #expect(pushed.applied == [survivor.opId])
        }
    }

    /// Quarantine means repair and retry. There is nothing to retry against here,
    /// so an operation left pending would fail forever.
    @Test("superseded work is dropped rather than quarantined")
    func supersededWorkIsDroppedRatherThanQuarantined() async throws {
        try await withSync { world in
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                Core.Issue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))

            let device = try world.device()
            _ = try await device.engine.pull()
            var patch = IssuePatch()
            patch.title = .set("Lost")
            try device.database.enqueue(
                .patchIssue(opId: UUID(), id: issue.id, at: Date(), body: patch))
            try repository.delete(issue.id, at: Date())

            _ = try await device.engine.pull()

            #expect(
                try device.database.allOperations().allSatisfy { $0.state != .quarantined },
                "work that can never succeed was quarantined for repair")
        }
    }

    /// It is the user's text, so deciding when they are finished with it is not
    /// ours to make on a timer.
    @Test("a superseded record is kept until dismissed")
    func supersededRecordIsKeptUntilDismissed() throws {
        let database = try ReplicaDatabase.inMemory()
        let operation = SyncOperation.putIssue(
            opId: UUID(), id: Core.Issue.ID(), at: Date(),
            body: IssueCreate(projectId: Project.ID(), title: "Gone"))

        try database.recordSuperseded(operation, current: nil, reason: .deletedElsewhere)
        #expect(try database.supersededWrites().count == 1)

        try database.dismissSuperseded(operation.opId)
        #expect(try database.supersededWrites().isEmpty)
    }

    @Test("recording the same operation twice keeps one record")
    func recordingTwiceKeepsOne() throws {
        let database = try ReplicaDatabase.inMemory()
        let operation = SyncOperation.deleteIssue(
            opId: UUID(), id: Core.Issue.ID(), at: Date())

        try database.recordSuperseded(operation, current: nil, reason: .deletedElsewhere)
        try database.recordSuperseded(operation, current: nil, reason: .rejectedByServer)

        #expect(try database.supersededWrites().count == 1)
    }

    @Test("superseded records come back newest first")
    func supersededRecordsComeBackNewestFirst() throws {
        let database = try ReplicaDatabase.inMemory()
        let now = Date()
        for (index, title) in ["oldest", "middle", "newest"].enumerated() {
            try database.recordSuperseded(
                .putIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: now,
                    body: IssueCreate(projectId: Project.ID(), title: title)),
                current: nil, reason: .deletedElsewhere,
                at: now.addingTimeInterval(Double(index) * 60))
        }

        let titles = try database.supersededWrites().compactMap { record -> String? in
            guard case .putIssue(_, _, _, let body) = record.operation else { return nil }
            return body.title
        }
        #expect(titles == ["newest", "middle", "oldest"])
    }

    @Test("nothing tombstoned means nothing dropped")
    func nothingTombstonedMeansNothingDropped() throws {
        let database = try ReplicaDatabase.inMemory()
        try database.enqueue(
            .putIssue(
                opId: UUID(), id: Core.Issue.ID(), at: Date(),
                body: IssueCreate(projectId: Project.ID(), title: "Fine")))

        #expect(try database.supersedePending(tombstoned: []).isEmpty)
        #expect(try database.allOperations().count == 1)
    }

    @Test("a tombstone with an empty queue is harmless")
    func tombstoneWithEmptyQueueIsHarmless() throws {
        let database = try ReplicaDatabase.inMemory()
        let dropped = try database.supersedePending(
            tombstoned: [SyncReference(entity: .issue, id: UUID())])
        #expect(dropped.isEmpty)
    }
}
