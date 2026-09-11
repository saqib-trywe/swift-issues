import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

private typealias Issue = Core.Issue
private typealias Comment = Core.Comment

@Suite("Sync push")
struct SyncPushRoutesTests {

    private struct Harness: Sendable {
        let client: any TestClientProtocol
        let token: String
        let project: Project
        let user: User
        let database: AppDatabase
    }

    private func withServer(
        kind: TokenKind = .human,
        _ body: @Sendable @escaping (Harness) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: kind, deviceId: "mac-1")

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            let harness = Harness(
                client: client, token: token.raw, project: project, user: user,
                database: database)
            try await body(harness)
        }
    }

    private func headers(_ token: String) -> HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(token)"
        fields[.contentType] = "application/json"
        return fields
    }

    private func push(_ batch: SyncPush) throws -> ByteBuffer {
        let data: Data = try JSONCoders.encoder.encode(batch)
        return ByteBuffer(data: data)
    }

    private func response(_ response: TestResponse) throws -> SyncPushResponse {
        try JSONCoders.decoder.decode(SyncPushResponse.self, from: Data(buffer: response.body))
    }

    private func createIssue(_ h: Harness, title: String) -> IssueCreate {
        IssueCreate(projectId: h.project.id, title: title)
    }

    @Test("a batch applies every operation and returns the current watermark")
    func batchAppliesEveryOperation() async throws {
        try await withServer { h in
            let first: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: "First"))
            let second: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: "Second"))
            let batch = SyncPush(deviceId: "mac-1", operations: [first, second])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                #expect(raw.status == .ok)
                let body = try self.response(raw)
                #expect(body.results.count == 2)
                #expect(body.results.allSatisfy { $0.outcome == .applied })
                #expect(body.watermark.sequence > 0)
            }
        }
    }

    /// The rule ADR 0004 exists to protect: one rejected operation must not stop
    /// the others. Head-of-line blocking would freeze all sync behind one bad
    /// record, invisibly, which is how an offline-first app dies.
    @Test("a rejected operation does not block the rest of the batch")
    func rejectedOperationDoesNotBlockTheBatch() async throws {
        try await withServer { h in
            let goodFirst: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: "Before"))
            // Blank title: valid JSON, invalid content.
            let bad: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: "   "))
            let goodLast: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: "After"))
            let batch = SyncPush(
                deviceId: "mac-1", operations: [goodFirst, bad, goodLast])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                #expect(raw.status == .ok, "a bad operation failed the whole batch")
                let body = try self.response(raw)
                let outcomes: [SyncOutcome] = body.results.map { $0.outcome }
                #expect(outcomes == [.applied, .rejected, .applied])
            }

            // And the two good ones are genuinely in the database.
            let stored: Int = try await h.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue") ?? 0
            }
            #expect(stored == 2)
        }
    }

    @Test("a rejected operation carries a problem describing what to fix")
    func rejectedOperationCarriesAProblem() async throws {
        try await withServer { h in
            let bad: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: ""))
            let batch = SyncPush(deviceId: "mac-1", operations: [bad])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                let body = try self.response(raw)
                let result = try #require(body.results.first)
                #expect(result.outcome == .rejected)
                let problem = try #require(result.problem)
                #expect(problem.errors?.first?.field == "title")
            }
        }
    }

    /// Replay safety. A client that never saw the response repeats the identical
    /// batch; already-applied operations dedupe on opId rather than applying twice.
    @Test("replaying a batch applies nothing twice")
    func replayAppliesNothingTwice() async throws {
        try await withServer { h in
            let operation: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: "Once"))
            let batch = SyncPush(deviceId: "mac-1", operations: [operation])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                let body = try self.response(raw)
                #expect(body.results.first?.outcome == .applied)
            }

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                let body = try self.response(raw)
                #expect(body.results.first?.outcome == .applied, "the replay changed its answer")
            }

            let stored: Int = try await h.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue") ?? 0
            }
            #expect(stored == 1, "a replayed operation created a second issue")
        }
    }

    /// The reason `superseded` exists. The write was valid but the entity is
    /// tombstoned, so the client must be told rather than shown a success while its
    /// text disappears.
    @Test("an operation against a tombstoned entity is superseded, not applied")
    func operationAgainstTombstoneIsSuperseded() async throws {
        try await withServer { h in
            let issues = IssueRepository(database: h.database)
            let draft = Issue.fixture(
                key: nil, projectId: h.project.id, title: "Doomed", reporterId: h.user.id)
            let created = try issues.create(draft)
            try issues.delete(created.id, at: Date())

            var patch = IssuePatch()
            patch.title = .set("Too late")
            let operation: SyncOperation = .patchIssue(
                opId: UUID(), id: created.id, at: Date(), body: patch)
            let batch = SyncPush(deviceId: "mac-1", operations: [operation])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                let body = try self.response(raw)
                let result = try #require(body.results.first)
                #expect(result.outcome == .superseded)
                // Carries what won, so the client can show it and hand the user
                // their losing text back.
                let current = try #require(result.current)
                guard case .issue(let issue) = current else {
                    Testing.Issue.record("expected an issue record")
                    return
                }
                #expect(issue.title == "Doomed")
                #expect(issue.isDeleted)
            }
        }
    }

    /// Per ADR 0006, a 401 is a top-level failure, never a per-operation rejection:
    /// the writes are valid and only the session is not, so the queue must be
    /// preserved rather than quarantined.
    @Test("an unauthenticated push fails at the top level, with no per-operation results")
    func unauthenticatedPushFailsAtTopLevel() async throws {
        try await withServer { h in
            let operation: SyncOperation = .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: self.createIssue(h, title: "Orphan"))
            let batch = SyncPush(deviceId: "mac-1", operations: [operation])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, body: try self.push(batch)
            ) { raw in
                #expect(raw.status == .unauthorized)
            }
        }
    }

    @Test("a comment operation applies alongside issue operations")
    func commentOperationApplies() async throws {
        try await withServer { h in
            let issueId = Issue.ID()
            let create: SyncOperation = .putIssue(
                opId: UUID(), id: issueId, at: Date(),
                body: self.createIssue(h, title: "With a comment"))
            let comment: SyncOperation = .putComment(
                opId: UUID(), id: Comment.ID(), at: Date(),
                body: CommentCreate(issueId: issueId, body: "First!"))
            let batch = SyncPush(deviceId: "mac-1", operations: [create, comment])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                let body = try self.response(raw)
                let outcomes: [SyncOutcome] = body.results.map { $0.outcome }
                #expect(outcomes == [.applied, .applied])
            }
        }
    }

    /// Causal order within a batch: the comment references an issue created by an
    /// earlier operation in the same batch, which only works because operations are
    /// applied in order rather than concurrently.
    @Test("an operation may depend on one earlier in the same batch")
    func operationMayDependOnAnEarlierOne() async throws {
        try await withServer { h in
            let issueId = Issue.ID()
            let comment: SyncOperation = .putComment(
                opId: UUID(), id: Comment.ID(), at: Date(),
                body: CommentCreate(issueId: issueId, body: "Out of order"))
            let create: SyncOperation = .putIssue(
                opId: UUID(), id: issueId, at: Date(),
                body: self.createIssue(h, title: "Created second"))
            // Deliberately the wrong way round: the client is responsible for causal
            // order, and the server rejects a reference it has not seen.
            let batch = SyncPush(deviceId: "mac-1", operations: [comment, create])

            try await h.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: self.headers(h.token),
                body: try self.push(batch)
            ) { raw in
                let body = try self.response(raw)
                let outcomes: [SyncOutcome] = body.results.map { $0.outcome }
                #expect(outcomes == [.rejected, .applied])
            }
        }
    }
}

@Suite("Sync push: every operation kind")
struct SyncPushOperationKindTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let token: String
        let database: AppDatabase
        let project: Project
        let user: User
        let issue: Issue
        let comment: Comment
        let label: Label
        let linkId: ID<IssueLabel>
    }

    private func withWorld(
        _ body: @Sendable @escaping (World) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .admin)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)

        let draft = Issue.fixture(key: nil, projectId: project.id, reporterId: user.id)
        let issue = try IssueRepository(database: database).create(draft)

        let comment = Comment.fixture(issueId: issue.id, authorId: user.id, body: "Existing")
        try CommentRepository(database: database).save(comment)

        let labels = LabelRepository(database: database)
        let label = try labels.save(Label.fixture(projectId: project.id, name: "bug"))
        try labels.attach(labelId: label.id, to: issue.id, at: Date())
        let linkId: ID<IssueLabel> = try #require(try linkIdentifier(database, issue.id, label.id))

        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            let world = World(
                client: client, token: token.raw, database: database, project: project,
                user: user, issue: issue, comment: comment, label: label, linkId: linkId)
            try await body(world)
        }
    }

    private func send(_ w: World, _ operations: [SyncOperation]) async throws -> [SyncOutcome] {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(w.token)"
        fields[.contentType] = "application/json"
        let batch = SyncPush(deviceId: "mac-1", operations: operations)
        let data: Data = try JSONCoders.encoder.encode(batch)

        var outcomes: [SyncOutcome] = []
        try await w.client.execute(
            uri: "/api/v1/sync/push", method: .post, headers: fields,
            body: ByteBuffer(data: data)
        ) { raw in
            #expect(raw.status == .ok)
            let body = try JSONCoders.decoder.decode(
                SyncPushResponse.self, from: Data(buffer: raw.body))
            outcomes = body.results.map { $0.outcome }
        }
        return outcomes
    }

    /// Every kind, because an operation kind the server cannot apply is a write
    /// that can never leave a client's queue — and it fails silently, on someone's
    /// laptop, not here.
    @Test("issue operations all apply")
    func issueOperationsApply() async throws {
        try await withWorld { w in
            var patch = IssuePatch()
            patch.priority = .set(.urgent)
            let newId = Issue.ID()
            let operations: [SyncOperation] = [
                .putIssue(
                    opId: UUID(), id: newId, at: Date(),
                    body: IssueCreate(projectId: w.project.id, title: "Fresh")),
                .patchIssue(opId: UUID(), id: newId, at: Date(), body: patch),
                .deleteIssue(opId: UUID(), id: newId, at: Date()),
            ]

            let outcomes = try await self.send(w, operations)
            #expect(outcomes == [.applied, .applied, .applied])
        }
    }

    @Test("comment operations all apply")
    func commentOperationsApply() async throws {
        try await withWorld { w in
            var patch = CommentPatch()
            patch.body = .set("Edited")
            let newId = Comment.ID()
            let operations: [SyncOperation] = [
                .putComment(
                    opId: UUID(), id: newId, at: Date(),
                    body: CommentCreate(issueId: w.issue.id, body: "Fresh")),
                .patchComment(opId: UUID(), id: newId, at: Date(), body: patch),
                .deleteComment(opId: UUID(), id: newId, at: Date()),
            ]

            let outcomes = try await self.send(w, operations)
            #expect(outcomes == [.applied, .applied, .applied])
        }
    }

    @Test("label operations all apply")
    func labelOperationsApply() async throws {
        try await withWorld { w in
            var patch = LabelPatch()
            patch.color = .set("#0E8A6B")
            let operations: [SyncOperation] = [
                .patchLabel(opId: UUID(), id: w.label.id, at: Date(), body: patch),
                .putLabel(
                    opId: UUID(), id: w.label.id, at: Date(),
                    body: LabelCreate(name: "bug", color: "#c0392b")),
                .deleteLabel(opId: UUID(), id: w.label.id, at: Date()),
            ]

            let outcomes = try await self.send(w, operations)
            #expect(outcomes == [.applied, .applied, .applied])
        }
    }

    /// Membership travels as link records, which is how concurrent adds by two
    /// users both survive.
    @Test("label link operations apply")
    func labelLinkOperationsApply() async throws {
        try await withWorld { w in
            let removeExisting: SyncOperation = .removeLabel(
                opId: UUID(), id: w.linkId, at: Date())
            let addAgain: SyncOperation = .addLabel(
                opId: UUID(), id: ID<IssueLabel>(), at: Date(), issueId: w.issue.id,
                labelId: w.label.id)

            let outcomes = try await self.send(w, [removeExisting, addAgain])
            #expect(outcomes == [.applied, .applied])

            let live: [Label.ID] = try LabelRepository(database: w.database)
                .labelIds(for: w.issue.id)
            #expect(live == [w.label.id])
        }
    }

    /// The cross-entity invariant holds on the sync path too — enforcing it only on
    /// the REST path would leave the offline queue as a way around it.
    @Test("a cross-project label link is rejected on the sync path as well")
    func crossProjectLinkRejectedOnSyncPath() async throws {
        try await withWorld { w in
            let otherProject = Project.fixture(id: Project.ID(), key: ProjectKey("OTHER")!)
            try ProjectRepository(database: w.database).save(otherProject)
            let foreign = try LabelRepository(database: w.database).save(
                Label.fixture(projectId: otherProject.id, name: "backend"))

            let operation: SyncOperation = .addLabel(
                opId: UUID(), id: ID<IssueLabel>(), at: Date(), issueId: w.issue.id,
                labelId: foreign.id)

            let outcomes = try await self.send(w, [operation])
            #expect(outcomes == [.rejected])
        }
    }

    @Test("an operation naming an entity the server has never seen is rejected")
    func unknownEntityIsRejected() async throws {
        try await withWorld { w in
            var patch = IssuePatch()
            patch.title = .set("Ghost")
            let operations: [SyncOperation] = [
                .patchIssue(opId: UUID(), id: Issue.ID(), at: Date(), body: patch),
                .deleteComment(opId: UUID(), id: Comment.ID(), at: Date()),
                .removeLabel(opId: UUID(), id: ID<IssueLabel>(), at: Date()),
            ]

            let outcomes = try await self.send(w, operations)
            #expect(outcomes == [.rejected, .rejected, .rejected])
        }
    }
}

private func linkIdentifier(
    _ database: AppDatabase, _ issueId: Core.Issue.ID, _ labelId: Label.ID
) throws -> ID<IssueLabel>? {
    try database.reader.read { db in
        guard
            let raw = try String.fetchOne(
                db, sql: "SELECT id FROM issue_label WHERE issue_id = ? AND label_id = ?",
                arguments: [issueId.rawValue.uuidString, labelId.rawValue.uuidString]),
            let uuid = UUID(uuidString: raw)
        else { return nil }
        return ID<IssueLabel>(uuid)
    }
}

@Suite("Sync push: unexpected failures")
struct SyncPushUnexpectedFailureTests {

    /// The safety net. A database-level failure is not a `ProblemError`, so without
    /// the catch-all it would propagate and fail the whole batch — stranding every
    /// operation after it, which is the head-of-line blocking ADR 0004 forbids.
    ///
    /// An assignee the server has never seen trips a foreign key, which is exactly
    /// such a failure.
    @Test("a database-level failure rejects only its own operation")
    func databaseFailureRejectsOnlyItsOwnOperation() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")

        var doomed = IssueCreate(projectId: project.id, title: "Assigned to a ghost")
        doomed.assigneeId = User.ID()

        let operations: [SyncOperation] = [
            .putIssue(opId: UUID(), id: Issue.ID(), at: Date(), body: doomed),
            .putIssue(
                opId: UUID(), id: Issue.ID(), at: Date(),
                body: IssueCreate(projectId: project.id, title: "Fine")),
        ]
        let batch = SyncPush(deviceId: "mac-1", operations: operations)
        let data: Data = try JSONCoders.encoder.encode(batch)

        let fields: HTTPFields = [
            .authorization: "Bearer \(token.raw)", .contentType: "application/json",
        ]

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: fields,
                body: ByteBuffer(data: data)
            ) { raw in
                #expect(raw.status == .ok, "a database failure failed the whole batch")
                let body = try JSONCoders.decoder.decode(
                    SyncPushResponse.self, from: Data(buffer: raw.body))
                let outcomes: [SyncOutcome] = body.results.map { $0.outcome }
                #expect(outcomes == [.rejected, .applied])
            }
        }

        let stored: Int = try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue") ?? 0
        }
        #expect(stored == 1, "the failed operation left a row behind")
    }
}
