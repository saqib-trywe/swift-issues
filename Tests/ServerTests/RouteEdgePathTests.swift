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

/// Edge paths across the resources: not-found, gone, and malformed identifiers.
///
/// These are the branches a happy-path suite leaves untouched, and they are the
/// ones a client actually hits when a record was deleted underneath it.
@Suite("Route edge paths")
struct RouteEdgePathTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let headers: HTTPFields
        let database: AppDatabase
        let project: Project
        let issue: Issue
        let user: User
    }

    private func withWorld(
        _ body: @Sendable @escaping (World) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .admin)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let issue = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, reporterId: user.id))
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: nil)
        let headers: HTTPFields = [
            .authorization: "Bearer \(token.raw)", .contentType: "application/json",
        ]

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            try await body(
                World(
                    client: client, headers: headers, database: database, project: project,
                    issue: issue, user: user))
        }
    }

    private func expect(
        _ w: World, _ uri: String, _ method: HTTPRequest.Method,
        _ status: HTTPResponse.Status, body: String? = nil
    ) async throws {
        let buffer: ByteBuffer? = body.map { ByteBuffer(string: $0) }
        try await w.client.execute(uri: uri, method: method, headers: w.headers, body: buffer) {
            response in
            #expect(response.status == status, "\(method) \(uri)")
        }
    }

    // MARK: Labels

    @Test("a deleted label is gone on read, patch and delete")
    func deletedLabelIsGone() async throws {
        try await withWorld { w in
            let labels = LabelRepository(database: w.database)
            let label = try labels.save(Label.fixture(projectId: w.project.id, name: "bug"))
            try labels.delete(label.id, at: Date())

            let projectId: String = w.project.id.rawValue.uuidString
            let labelId: String = label.id.rawValue.uuidString
            let uri = "/api/v1/projects/\(projectId)/labels/\(labelId)"

            try await self.expect(w, uri, .delete, .gone)
            try await self.expect(w, uri, .patch, .gone, body: #"{"name":"renamed"}"#)
        }
    }

    @Test("an unknown label is not found")
    func unknownLabelIsNotFound() async throws {
        try await withWorld { w in
            let projectId: String = w.project.id.rawValue.uuidString
            let labelId: String = UUID().uuidString
            let uri = "/api/v1/projects/\(projectId)/labels/\(labelId)"

            try await self.expect(w, uri, .delete, .notFound)
        }
    }

    @Test("a label path with a malformed identifier is not found")
    func malformedLabelIdentifierIsNotFound() async throws {
        try await withWorld { w in
            let projectId: String = w.project.id.rawValue.uuidString

            try await self.expect(
                w, "/api/v1/projects/\(projectId)/labels/not-a-uuid", .delete, .notFound)
            try await self.expect(w, "/api/v1/projects/not-a-uuid/labels", .get, .notFound)
        }
    }

    @Test("labelling an issue the server has never seen is not found")
    func labellingUnknownIssueIsNotFound() async throws {
        try await withWorld { w in
            let issueId: String = UUID().uuidString

            try await self.expect(
                w, "/api/v1/issues/\(issueId)/labels", .patch, .notFound,
                body: #"{"add":[],"remove":[]}"#)
        }
    }

    // MARK: Comments

    @Test("a comment path with a malformed identifier is not found")
    func malformedCommentIdentifierIsNotFound() async throws {
        try await withWorld { w in
            try await self.expect(w, "/api/v1/comments/not-a-uuid", .get, .notFound)
            try await self.expect(
                w, "/api/v1/comments/not-a-uuid", .patch, .notFound,
                body: #"{"body":"edited"}"#)
            try await self.expect(w, "/api/v1/comments/not-a-uuid", .delete, .notFound)
        }
    }

    @Test("an unknown comment is not found")
    func unknownCommentIsNotFound() async throws {
        try await withWorld { w in
            let id: String = UUID().uuidString

            try await self.expect(w, "/api/v1/comments/\(id)", .get, .notFound)
        }
    }
}

@Suite("Sync push: idempotent re-creates and invalid patches")
struct SyncPushIdempotencyTests {

    private func push(
        _ database: AppDatabase, _ token: String, _ operations: [SyncOperation]
    ) async throws -> [SyncOutcome] {
        let batch = SyncPush(deviceId: "mac-1", operations: operations)
        let data: Data = try JSONCoders.encoder.encode(batch)
        let headers: HTTPFields = [
            .authorization: "Bearer \(token)", .contentType: "application/json",
        ]

        let application = Application(router: IssuesRouter.build(database: database))
        return try await application.test(.router) { client -> [SyncOutcome] in
            try await client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: headers,
                body: ByteBuffer(data: data)
            ) { raw -> [SyncOutcome] in
                #expect(raw.status == .ok)
                let body = try JSONCoders.decoder.decode(
                    SyncPushResponse.self, from: Data(buffer: raw.body))
                return body.results.map { $0.outcome }
            }
        }
    }

    private func world() throws -> (AppDatabase, Project, User, String) {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")
        return (database, project, user, token.raw)
    }

    /// A create for a live entity that already exists is the retry an offline client
    /// makes, and applies without duplicating — distinct from the tombstoned case,
    /// which is superseded.
    @Test("re-creating a live entity applies rather than superseding")
    func recreatingLiveEntityApplies() async throws {
        let (database, project, user, token) = try world()
        let existing = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, title: "Live", reporterId: user.id))
        let comment = Comment.fixture(issueId: existing.id, authorId: user.id, body: "Here")
        try CommentRepository(database: database).save(comment)

        let operations: [SyncOperation] = [
            .putIssue(
                opId: UUID(), id: existing.id, at: Date(),
                body: IssueCreate(projectId: project.id, title: "Live")),
            .putComment(
                opId: UUID(), id: comment.id, at: Date(),
                body: CommentCreate(issueId: existing.id, body: "Here")),
        ]

        let outcomes = try await push(database, token, operations)
        #expect(outcomes == [.applied, .applied])
    }

    /// Validation applies on the sync path too. A rule enforced only on the REST
    /// path would leave the offline queue as a way around it.
    @Test("an invalid patch is rejected on the sync path")
    func invalidPatchIsRejectedOnSyncPath() async throws {
        let (database, project, user, token) = try world()
        let existing = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, title: "Live", reporterId: user.id))
        let comment = Comment.fixture(issueId: existing.id, authorId: user.id, body: "Here")
        try CommentRepository(database: database).save(comment)

        var blankTitle = IssuePatch()
        blankTitle.title = .set("   ")
        var blankBody = CommentPatch()
        blankBody.body = .set("  ")

        let operations: [SyncOperation] = [
            .patchIssue(opId: UUID(), id: existing.id, at: Date(), body: blankTitle),
            .patchComment(opId: UUID(), id: comment.id, at: Date(), body: blankBody),
        ]

        let outcomes = try await push(database, token, operations)
        #expect(outcomes == [.rejected, .rejected])
    }
}

@Suite("Sync push: authority")
struct SyncPushAuthorityTests {

    private func push(
        _ database: AppDatabase, _ token: String, _ operations: [SyncOperation]
    ) async throws -> [SyncOutcome] {
        let batch = SyncPush(deviceId: "mac-1", operations: operations)
        let data: Data = try JSONCoders.encoder.encode(batch)
        let headers: HTTPFields = [
            .authorization: "Bearer \(token)", .contentType: "application/json",
        ]

        let application = Application(router: IssuesRouter.build(database: database))
        return try await application.test(.router) { client -> [SyncOutcome] in
            try await client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: headers,
                body: ByteBuffer(data: data)
            ) { raw -> [SyncOutcome] in
                #expect(raw.status == .ok)
                let body = try JSONCoders.decoder.decode(
                    SyncPushResponse.self, from: Data(buffer: raw.body))
                return body.results.map { $0.outcome }
            }
        }
    }

    /// Someone else's comment, reached through the sync queue rather than REST.
    /// Authority rules have to hold on both paths, or the offline queue becomes a
    /// way around them.
    private func worldWithAnotherUsersComment(
        callerRole: Role
    ) throws -> (AppDatabase, String, Comment) {
        let database = try AppDatabase.inMemory()
        let users = UserRepository(database: database)
        let caller = User.fixture(email: "caller@example.com", role: callerRole)
        let stranger = User.fixture(email: "stranger@example.com")
        try users.save(caller)
        try users.save(stranger)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let issue = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, reporterId: stranger.id))
        let comment = Comment.fixture(
            issueId: issue.id, authorId: stranger.id, body: "Theirs")
        try CommentRepository(database: database).save(comment)
        let token = try SessionRepository(database: database).create(
            for: caller.id, kind: .human, deviceId: "mac-1")
        return (database, token.raw, comment)
    }

    @Test("editing another user's comment is rejected even for an admin")
    func editingAnothersCommentIsRejected() async throws {
        let (database, token, comment) = try worldWithAnotherUsersComment(callerRole: .admin)
        var patch = CommentPatch()
        patch.body = .set("Rewritten")

        let outcomes = try await push(
            database, token,
            [.patchComment(opId: UUID(), id: comment.id, at: Date(), body: patch)])

        #expect(outcomes == [.rejected])
    }

    @Test("a member deleting another user's comment is rejected")
    func memberDeletingAnothersCommentIsRejected() async throws {
        let (database, token, comment) = try worldWithAnotherUsersComment(callerRole: .member)

        let outcomes = try await push(
            database, token, [.deleteComment(opId: UUID(), id: comment.id, at: Date())])

        #expect(outcomes == [.rejected])
    }

    /// An admin may remove someone else's comment even though they may not rewrite
    /// it — the asymmetry from ticket 01, holding on the sync path too.
    @Test("an admin deleting another user's comment applies")
    func adminDeletingAnothersCommentApplies() async throws {
        let (database, token, comment) = try worldWithAnotherUsersComment(callerRole: .admin)

        let outcomes = try await push(
            database, token, [.deleteComment(opId: UUID(), id: comment.id, at: Date())])

        #expect(outcomes == [.applied])
    }

    /// Labels are created through their Project, not invented by a sync operation:
    /// the derived id depends on the project, so a label the server has never seen
    /// cannot be conjured from the queue.
    @Test("a label operation for an unknown label is rejected")
    func unknownLabelOperationIsRejected() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")

        let operations: [SyncOperation] = [
            .putLabel(
                opId: UUID(), id: Label.ID(), at: Date(),
                body: LabelCreate(name: "ghost", color: "#000000")),
            .patchLabel(opId: UUID(), id: Label.ID(), at: Date(), body: LabelPatch()),
            .deleteLabel(opId: UUID(), id: Label.ID(), at: Date()),
        ]

        let outcomes = try await push(database, token.raw, operations)
        #expect(outcomes == [.rejected, .rejected, .rejected])
    }
}

@Suite("Sync push: comment supersession and label rename")
struct SyncPushCommentSupersessionTests {

    private func push(
        _ database: AppDatabase, _ token: String, _ operations: [SyncOperation]
    ) async throws -> [SyncResult] {
        let batch = SyncPush(deviceId: "mac-1", operations: operations)
        let data: Data = try JSONCoders.encoder.encode(batch)
        let headers: HTTPFields = [
            .authorization: "Bearer \(token)", .contentType: "application/json",
        ]

        let application = Application(router: IssuesRouter.build(database: database))
        return try await application.test(.router) { client -> [SyncResult] in
            try await client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: headers,
                body: ByteBuffer(data: data)
            ) { raw -> [SyncResult] in
                #expect(raw.status == .ok)
                let body = try JSONCoders.decoder.decode(
                    SyncPushResponse.self, from: Data(buffer: raw.body))
                return body.results
            }
        }
    }

    /// The Comment equivalent of the tombstoned-Issue case. Deletion is terminal for
    /// comments too, and the winning record has to come back so a client can tell the
    /// user their edit could not be applied and hand the text back.
    @Test("an edit to a deleted comment is superseded, carrying the tombstone")
    func editToDeletedCommentIsSuperseded() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let issue = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, reporterId: user.id))
        let comments = CommentRepository(database: database)
        let comment = Comment.fixture(issueId: issue.id, authorId: user.id, body: "Doomed")
        try comments.save(comment)
        try comments.delete(comment.id, at: Date())
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")

        var patch = CommentPatch()
        patch.body = .set("Too late")
        let results = try await push(
            database, token.raw,
            [.patchComment(opId: UUID(), id: comment.id, at: Date(), body: patch)])

        let result = try #require(results.first)
        #expect(result.outcome == .superseded)
        guard case .comment(let winner) = try #require(result.current) else {
            Testing.Issue.record("expected a comment record")
            return
        }
        #expect(winner.isDeleted)
        // The text is gone, because deleting a comment clears it.
        #expect(winner.body == nil)
    }

    @Test("renaming a label through sync applies")
    func renamingLabelThroughSyncApplies() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let label = try LabelRepository(database: database).save(
            Label.fixture(projectId: project.id, name: "backend"))
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")

        var patch = LabelPatch()
        patch.name = .set("back-end")
        let results = try await push(
            database, token.raw,
            [.patchLabel(opId: UUID(), id: label.id, at: Date(), body: patch)])

        #expect(results.first?.outcome == .applied)
        // The id deliberately does not follow the name: derivation is a
        // creation-time device only.
        #expect(try LabelRepository(database: database).find(label.id)?.name == "back-end")
    }

    @Test("a blank label name is rejected through sync")
    func blankLabelNameRejectedThroughSync() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let label = try LabelRepository(database: database).save(
            Label.fixture(projectId: project.id, name: "backend"))
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")

        var patch = LabelPatch()
        patch.name = .set("   ")
        let results = try await push(
            database, token.raw,
            [.patchLabel(opId: UUID(), id: label.id, at: Date(), body: patch)])

        #expect(results.first?.outcome == .rejected)
    }
}
