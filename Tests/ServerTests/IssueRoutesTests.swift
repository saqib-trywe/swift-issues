import Core
import Foundation
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

private typealias Issue = Core.Issue

@Suite("Issue routes")
struct IssueRoutesTests {

    private struct Harness: Sendable {
        let client: any TestClientProtocol
        let token: String
        let projectId: Project.ID
        let userId: User.ID
    }

    private func withServer(
        role: Role = .member,
        kind: TokenKind = .human,
        _ body: @Sendable @escaping (Harness, AppDatabase) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: role)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: kind, deviceId: nil)

        try await Application(router: IssuesRouter.build(database: database)).test(.router) {
            client in
            try await body(
                Harness(
                    client: client, token: token.raw, projectId: project.id, userId: user.id),
                database)
        }
    }

    private func headers(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private func createBody(_ projectId: Project.ID, title: String = "Sync stalls") -> String {
        #"{"projectId":"\#(projectId.rawValue.uuidString)","title":"\#(title)","description":"","status":"todo","priority":"none","labelIds":[]}"#
    }

    /// Members do tracker work, so creating an Issue is not an Admin action —
    /// unlike creating a Project.
    @Test("a member can create an issue and the server assigns its key")
    func memberCanCreateAndKeyIsAssigned() async throws {
        try await withServer { h, _ in
            try await h.client.execute(
                uri: "/api/v1/issues/\(UUID().uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { response in
                #expect(response.status == .created)
                let issue = try JSONCoders.decoder.decode(
                    Issue.self, from: Data(buffer: response.body))
                #expect(issue.key == IssueKey("PROJ-1"))
            }
        }
    }

    /// The reporter is set from the authenticated caller and is immutable. A body
    /// claiming a different reporter must not be believed.
    @Test("the reporter comes from the token, not the body")
    func reporterComesFromTheToken() async throws {
        try await withServer { h, _ in
            let spoofed =
                #"{"projectId":"\#(h.projectId.rawValue.uuidString)","title":"X","description":"","status":"todo","priority":"none","labelIds":[],"reporterId":"\#(UUID().uuidString)"}"#

            try await h.client.execute(
                uri: "/api/v1/issues/\(UUID().uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: spoofed)
            ) { response in
                let issue = try JSONCoders.decoder.decode(
                    Issue.self, from: Data(buffer: response.body))
                #expect(issue.reporterId == h.userId, "a spoofed reporter was accepted")
            }
        }
    }

    /// `via` is set server-side from the token's kind, which is the whole point of
    /// the field: answering "which of these did the bot file?".
    @Test("via is set from the token kind, not the body")
    func viaComesFromTheTokenKind() async throws {
        try await withServer(kind: .agent) { h, _ in
            let claiming =
                #"{"projectId":"\#(h.projectId.rawValue.uuidString)","title":"X","description":"","status":"todo","priority":"none","labelIds":[],"via":"human"}"#

            try await h.client.execute(
                uri: "/api/v1/issues/\(UUID().uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: claiming)
            ) { response in
                let issue = try JSONCoders.decoder.decode(
                    Issue.self, from: Data(buffer: response.body))
                #expect(issue.via == .agent, "an agent's write claimed to be human")
            }
        }
    }

    /// Humans and agents hold keys, not UUIDs; without this every CLI and MCP call
    /// needs a lookup round trip first.
    @Test("an issue is addressable by key as well as by id")
    func addressableByKey() async throws {
        try await withServer { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues/PROJ-1", method: .get, headers: headers(h.token)
            ) { response in
                #expect(response.status == .ok)
                let issue = try JSONCoders.decoder.decode(
                    Issue.self, from: Data(buffer: response.body))
                #expect(issue.id == Issue.ID(id))
            }
        }
    }

    @Test("an unknown id or key is not found")
    func unknownIsNotFound() async throws {
        try await withServer { h, _ in
            for uri in ["/api/v1/issues/\(UUID().uuidString)", "/api/v1/issues/PROJ-99"] {
                try await h.client.execute(uri: uri, method: .get, headers: headers(h.token)) {
                    response in
                    #expect(response.status == .notFound, "\(uri)")
                }
            }
        }
    }

    /// The distinction ticket 11 gives its own CLI exit code: "that issue was
    /// deleted" is a different message from "no such issue".
    @Test("a deleted issue is gone, not merely not-found")
    func deletedIssueIsGone() async throws {
        try await withServer { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .delete, headers: headers(h.token)
            ) { response in
                #expect(response.status == .noContent)
            }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .get, headers: headers(h.token)
            ) { response in
                #expect(response.status == .gone)
            }
            // And by key, since the key still resolves — keys are never reused.
            try await h.client.execute(
                uri: "/api/v1/issues/PROJ-1", method: .get, headers: headers(h.token)
            ) { response in
                #expect(response.status == .gone)
            }
        }
    }

    @Test("patching a deleted issue is gone rather than a silent no-op")
    func patchingDeletedIssueIsGone() async throws {
        try await withServer { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { _ in }
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .delete, headers: headers(h.token)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .patch,
                headers: headers(h.token), body: ByteBuffer(string: #"{"title":"Nope"}"#)
            ) { response in
                #expect(response.status == .gone)
            }
        }
    }

    @Test("a patch changes only the fields it names")
    func patchChangesOnlyNamedFields() async throws {
        try await withServer { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(string: createBody(h.projectId, title: "Keep me"))
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .patch,
                headers: headers(h.token), body: ByteBuffer(string: #"{"status":"inProgress"}"#)
            ) { response in
                #expect(response.status == .ok)
                let issue = try JSONCoders.decoder.decode(
                    Issue.self, from: Data(buffer: response.body))
                #expect(issue.status == .inProgress)
                #expect(issue.title == "Keep me", "an unmentioned field was overwritten")
            }
        }
    }

    @Test("a blank title is rejected with a field-level error")
    func blankTitleIsRejected() async throws {
        try await withServer { h, _ in
            try await h.client.execute(
                uri: "/api/v1/issues/\(UUID().uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(string: createBody(h.projectId, title: "   "))
            ) { response in
                #expect(response.status == .unprocessableContent)
                let problem = try JSONCoders.decoder.decode(
                    Problem.self, from: Data(buffer: response.body))
                #expect(problem.errors?.first?.field == "title")
            }
        }
    }

    /// ADR 0007: agents never get destructive capability, whatever their owner's
    /// role. Deletion is a tombstone nobody can undo through the API.
    @Test("an agent cannot delete an issue even though it can create one")
    func agentCannotDelete() async throws {
        try await withServer(role: .admin, kind: .agent) { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { response in
                #expect(response.status == .created)
            }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .delete, headers: headers(h.token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// Ticket 01: Issue delete is reporter or Admin. A Member who did not report it
    /// has the `cancelled` status as their normal "make it go away" path.
    @Test("a member cannot delete someone else's issue")
    func memberCannotDeleteAnothersIssue() async throws {
        try await withServer(role: .member) { h, database in
            let stranger = User.fixture(email: "other@example.com")
            try UserRepository(database: database).save(stranger)
            let theirs = try IssueRepository(database: database).create(
                Issue.fixture(key: nil, projectId: h.projectId, reporterId: stranger.id))

            try await h.client.execute(
                uri: "/api/v1/issues/\(theirs.id.rawValue.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("an admin can delete an issue they did not report")
    func adminCanDeleteAnothersIssue() async throws {
        try await withServer(role: .admin) { h, database in
            let stranger = User.fixture(email: "other@example.com")
            try UserRepository(database: database).save(stranger)
            let theirs = try IssueRepository(database: database).create(
                Issue.fixture(key: nil, projectId: h.projectId, reporterId: stranger.id))

            try await h.client.execute(
                uri: "/api/v1/issues/\(theirs.id.rawValue.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test("listing returns a paginated envelope of live issues")
    func listingReturnsLiveIssues() async throws {
        try await withServer { h, _ in
            for title in ["First", "Second"] {
                try await h.client.execute(
                    uri: "/api/v1/issues/\(UUID().uuidString)", method: .put,
                    headers: headers(h.token),
                    body: ByteBuffer(string: createBody(h.projectId, title: title))
                ) { _ in }
            }

            try await h.client.execute(
                uri: "/api/v1/issues", method: .get, headers: headers(h.token)
            ) { response in
                #expect(response.status == .ok)
                let page = try JSONCoders.decoder.decode(
                    Paginated<Issue>.self, from: Data(buffer: response.body))
                #expect(page.items.count == 2)
                #expect(Set(page.items.map(\.title)) == ["First", "Second"])
            }
        }
    }

    /// Ticket 06: lists exclude deleted records. Tombstones are sync machinery —
    /// surfacing them in a list would invite clients to build an ad-hoc sync on
    /// top of the resource API.
    @Test("a deleted issue disappears from the listing")
    func deletedIssueLeavesTheListing() async throws {
        try await withServer { h, _ in
            let doomed = UUID()
            for (id, title) in [(doomed, "Doomed"), (UUID(), "Survivor")] {
                try await h.client.execute(
                    uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                    headers: headers(h.token),
                    body: ByteBuffer(string: createBody(h.projectId, title: title))
                ) { _ in }
            }
            try await h.client.execute(
                uri: "/api/v1/issues/\(doomed.uuidString)", method: .delete,
                headers: headers(h.token)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues", method: .get, headers: headers(h.token)
            ) { response in
                let page = try JSONCoders.decoder.decode(
                    Paginated<Issue>.self, from: Data(buffer: response.body))
                #expect(page.items.map(\.title) == ["Survivor"])
            }
        }
    }

    /// The offline-retry guarantee, for Issues this time: a client that never saw
    /// the response repeats the identical PUT and must not create a second issue
    /// with a second Issue Key burned.
    @Test("repeating an identical create is idempotent and burns no extra key")
    func identicalCreateIsIdempotent() async throws {
        try await withServer { h, _ in
            let id = UUID()
            let body = createBody(h.projectId)

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .created)
            }
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .ok)
                let issue = try JSONCoders.decoder.decode(
                    Issue.self, from: Data(buffer: response.body))
                #expect(issue.key == IssueKey("PROJ-1"), "the retry burned a second key")
            }
        }
    }

    @Test("re-creating an id with different content is a conflict")
    func recreateWithDifferentContentConflicts() async throws {
        try await withServer { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(string: createBody(h.projectId, title: "Original"))
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token),
                body: ByteBuffer(string: createBody(h.projectId, title: "Different"))
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    /// Re-creating a tombstoned id is gone, not a fresh create: the id has been
    /// used, and resurrecting it would undo a deletion.
    @Test("re-creating a deleted id is gone")
    func recreatingDeletedIDIsGone() async throws {
        try await withServer { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { _ in }
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .delete, headers: headers(h.token)
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { response in
                #expect(response.status == .gone)
            }
        }
    }

    /// A rule enforced on create but not on patch is not enforced.
    @Test(
        "invalid values are rejected on patch as well as on create",
        arguments: [#"{"title":"   "}"#, #"{"description":"\#(String(repeating: "a", count: 70000))"}"#]
    )
    func invalidPatchIsRejected(body: String) async throws {
        try await withServer { h, _ in
            let id = UUID()
            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .put,
                headers: headers(h.token), body: ByteBuffer(string: createBody(h.projectId))
            ) { _ in }

            try await h.client.execute(
                uri: "/api/v1/issues/\(id.uuidString)", method: .patch,
                headers: headers(h.token), body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }

    /// A write addresses an Issue by id, never by key: a key is server-assigned, so
    /// a client creating one offline does not have it yet. Writing by key would be
    /// an address the creating client cannot form.
    @Test("writes by key are rejected", arguments: [HTTPRequest.Method.put, .patch, .delete])
    func writesByKeyAreRejected(method: HTTPRequest.Method) async throws {
        try await withServer { h, _ in
            try await h.client.execute(
                uri: "/api/v1/issues/PROJ-1", method: method, headers: headers(h.token),
                body: ByteBuffer(string: createBody(h.projectId))
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("a reference that is neither a UUID nor a key is not found")
    func nonsenseReferenceIsNotFound() async throws {
        try await withServer { h, _ in
            try await h.client.execute(
                uri: "/api/v1/issues/not-an-id", method: .get, headers: headers(h.token)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
