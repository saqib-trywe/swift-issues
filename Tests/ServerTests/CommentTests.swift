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

@Suite("Comment repository")
struct CommentRepositoryTests {

    private struct World {
        let database: AppDatabase
        let comments: CommentRepository
        let issue: Issue
        let author: User
    }

    private func world() throws -> World {
        let database = try AppDatabase.inMemory()
        let author = User.fixture()
        try UserRepository(database: database).save(author)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let issue = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, reporterId: author.id))
        return World(
            database: database, comments: CommentRepository(database: database),
            issue: issue, author: author)
    }

    @Test("a comment round trips with its author and attribution")
    func roundTrips() throws {
        let w = try world()
        let comment = Comment.fixture(
            issueId: w.issue.id, authorId: w.author.id, body: "Looks right.", via: .agent)

        try w.comments.save(comment)
        let loaded = try w.comments.find(comment.id)

        #expect(loaded?.body == "Looks right.")
        #expect(loaded?.authorId == w.author.id)
        #expect(loaded?.via == .agent)
    }

    /// Deleting a comment clears its text everywhere: people delete comments for
    /// what is *in* them. The tombstone keeps only ids and timestamps.
    @Test("deleting clears the body rather than only flagging the row")
    func deleteClearsTheBody() throws {
        let w = try world()
        let comment = Comment.fixture(issueId: w.issue.id, authorId: w.author.id, body: "Oops")
        try w.comments.save(comment)

        try w.comments.delete(comment.id, at: Date())

        let loaded = try w.comments.find(comment.id)
        #expect(loaded?.isDeleted == true)
        #expect(loaded?.body == nil, "the text survived a deletion")

        // And genuinely gone from the column, not merely absent from the model.
        let stored = try w.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM comment")
        }
        #expect(stored == nil)
    }

    @Test("listing a thread excludes deleted comments")
    func threadExcludesDeleted() throws {
        let w = try world()
        let kept = Comment.fixture(issueId: w.issue.id, authorId: w.author.id, body: "Kept")
        let removed = Comment.fixture(issueId: w.issue.id, authorId: w.author.id, body: "Removed")
        try w.comments.save(kept)
        try w.comments.save(removed)
        try w.comments.delete(removed.id, at: Date())

        let thread = try w.comments.thread(for: w.issue.id)

        #expect(thread.map(\.body) == ["Kept"])
    }

    @Test("saving and deleting advance the change cursor")
    func mutationsAdvanceTheCursor() throws {
        let w = try world()
        func sequence() throws -> Int {
            try w.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM change_cursor") ?? 0
            }
        }
        let before = try sequence()
        let comment = Comment.fixture(issueId: w.issue.id, authorId: w.author.id)

        try w.comments.save(comment)
        let afterSave = try sequence()
        #expect(afterSave > before)

        try w.comments.delete(comment.id, at: Date())
        #expect(try sequence() > afterSave)
    }

    /// Ticket 08: a reference the server has not seen is rejected rather than
    /// accepted and reaped later.
    @Test("a comment on an issue that does not exist is rejected")
    func commentOnUnknownIssueIsRejected() throws {
        let w = try world()

        #expect(throws: (any Error).self) {
            try w.comments.save(
                Comment.fixture(issueId: Issue.ID(), authorId: w.author.id))
        }
    }
}

@Suite("Comment routes")
struct CommentRoutesTests {

    private struct Harness: Sendable {
        let client: any TestClientProtocol
        let token: String
        let issueId: Issue.ID
        let userId: User.ID
        let database: AppDatabase
    }

    private func withServer(
        role: Role = .member,
        kind: TokenKind = .human,
        _ body: @Sendable @escaping (Harness) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: role)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let issue = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, reporterId: user.id))
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: kind, deviceId: nil)

        try await Application(router: IssuesRouter.build(database: database)).test(.router) {
            client in
            try await body(
                Harness(
                    client: client, token: token.raw, issueId: issue.id, userId: user.id,
                    database: database))
        }
    }

    private func headers(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    /// The author is the authenticated caller, and `via` comes from the token kind —
    /// a body claiming otherwise is not believed.
    @Test("creating a comment takes its author and attribution from the token")
    func createTakesAuthorFromToken() async throws {
        try await withServer(kind: .agent) { h in
            let body =
                #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Filed a follow-up.","authorId":"\#(UUID().uuidString)","via":"human"}"#

            try await h.client.execute(
                uri: "/api/v1/comments/\(UUID().uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .created)
                let comment = try JSONCoders.decoder.decode(
                    Comment.self, from: Data(buffer: response.body))
                #expect(comment.authorId == h.userId, "a spoofed author was accepted")
                #expect(comment.via == .agent, "an agent's comment claimed to be human")
            }
        }
    }

    @Test("an empty comment is rejected")
    func emptyCommentIsRejected() async throws {
        try await withServer { h in
            try await h.client.execute(
                uri: "/api/v1/comments/\(UUID().uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"   "}"#)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }

    @Test("a thread lists under its issue")
    func threadListsUnderIssue() async throws {
        try await withServer { h in
            for text in ["First", "Second"] {
                try await h.client.execute(
                    uri: "/api/v1/comments/\(UUID().uuidString)", method: .put,
                    headers: headers(h.token),
                    body: ByteBuffer(
                        string:
                            #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"\#(text)"}"#)
                ) { _ in }
            }

            try await h.client.execute(
                uri: "/api/v1/issues/\(h.issueId.rawValue.uuidString)/comments", method: .get,
                headers: headers(h.token)
            ) { response in
                #expect(response.status == .ok)
                let page = try JSONCoders.decoder.decode(
                    Paginated<Comment>.self, from: Data(buffer: response.body))
                #expect(page.items.compactMap(\.body) == ["First", "Second"])
            }
        }
    }

    /// Ticket 01: edit is author-only. Silent edits by others would be a trust
    /// problem in a discussion thread.
    @Test("only the author may edit a comment")
    func onlyAuthorMayEdit() async throws {
        try await withServer(role: .admin) { h in
            let stranger = User.fixture(email: "other@example.com")
            try UserRepository(database: h.database).save(stranger)
            let theirs = Comment.fixture(
                issueId: h.issueId, authorId: stranger.id, body: "Theirs")
            try CommentRepository(database: h.database).save(theirs)

            // Even an Admin may not rewrite someone else's words.
            try await h.client.execute(
                uri: "/api/v1/comments/\(theirs.id.rawValue.uuidString)", method: .patch,
                headers: headers(h.token), body: ByteBuffer(string: #"{"body":"Rewritten"}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// Ticket 01: delete is author or Admin. An Admin can remove someone else's
    /// comment even though they cannot rewrite it.
    @Test("an admin may delete another's comment even though they cannot edit it")
    func adminMayDeleteButNotEdit() async throws {
        try await withServer(role: .admin) { h in
            let stranger = User.fixture(email: "other@example.com")
            try UserRepository(database: h.database).save(stranger)
            let theirs = Comment.fixture(issueId: h.issueId, authorId: stranger.id)
            try CommentRepository(database: h.database).save(theirs)

            try await h.client.execute(
                uri: "/api/v1/comments/\(theirs.id.rawValue.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test("a member may not delete another's comment")
    func memberMayNotDeleteAnothers() async throws {
        try await withServer(role: .member) { h in
            let stranger = User.fixture(email: "other@example.com")
            try UserRepository(database: h.database).save(stranger)
            let theirs = Comment.fixture(issueId: h.issueId, authorId: stranger.id)
            try CommentRepository(database: h.database).save(theirs)

            try await h.client.execute(
                uri: "/api/v1/comments/\(theirs.id.rawValue.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("a deleted comment is gone")
    func deletedCommentIsGone() async throws {
        try await withServer { h in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Oops"}"#)
            ) { _ in }
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .get, headers: headers(h.token)
            ) { response in
                #expect(response.status == .gone)
            }
        }
    }

    @Test("an agent may not delete a comment")
    func agentMayNotDelete() async throws {
        try await withServer(kind: .agent) { h in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Mine"}"#)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// The offline-retry guarantee, for Comments. This is the third resource with
    /// create-only PUT, and the third time these three paths needed their own tests.
    @Test("repeating an identical create is idempotent")
    func identicalCreateIsIdempotent() async throws {
        try await withServer { h in
            let id = UUID()
            let body = #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Once"}"#

            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .created)
            }
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("re-creating an id with different text is a conflict")
    func recreateWithDifferentTextConflicts() async throws {
        try await withServer { h in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Original"}"#)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Different"}"#)
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    /// Re-creating a tombstoned id must not resurrect the text a deletion removed.
    @Test("re-creating a deleted comment id is gone")
    func recreatingDeletedIDIsGone() async throws {
        try await withServer { h in
            let id = UUID()
            let body = #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Oops"}"#
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { _ in }
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .gone)
            }
        }
    }

    @Test("a comment on an issue the server has never seen is not found")
    func commentOnUnknownIssueIsNotFound() async throws {
        try await withServer { h in
            try await h.client.execute(
                uri: "/api/v1/comments/\(UUID().uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(UUID().uuidString)","body":"Orphan"}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("a thread under a non-UUID issue reference is not found")
    func threadUnderNonUUIDIsNotFound() async throws {
        try await withServer { h in
            try await h.client.execute(
                uri: "/api/v1/issues/not-a-uuid/comments", method: .get, headers: headers(h.token)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// The other half of the author-only rule. Asserting only that strangers are
    /// refused would pass even if nobody could edit at all.
    @Test("the author can edit their own comment, and the edit is visible")
    func authorCanEditOwnComment() async throws {
        try await withServer { h in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"First go"}"#)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .patch,
                headers: headers(h.token), body: ByteBuffer(string: #"{"body":"Second go"}"#)
            ) { response in
                #expect(response.status == .ok)
                let comment = try JSONCoders.decoder.decode(
                    Comment.self, from: Data(buffer: response.body))
                #expect(comment.body == "Second go")
                // Surfaced as "edited": a silent edit in a discussion thread is a
                // trust problem.
                #expect(comment.updatedAt > comment.createdAt)
            }
        }
    }

    @Test("an edit to an empty body is rejected")
    func editToEmptyBodyIsRejected() async throws {
        try await withServer { h in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(
                    string: #"{"issueId":"\#(h.issueId.rawValue.uuidString)","body":"Text"}"#)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/comments/\(id.uuidString)", method: .patch,
                headers: headers(h.token), body: ByteBuffer(string: #"{"body":"   "}"#)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }
}
