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

@Suite("Sync pull")
struct SyncPullRoutesTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let headers: HTTPFields
        let database: AppDatabase
        let project: Project
        let user: User
    }

    private func withWorld(
        _ body: @Sendable @escaping (World) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .member)
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: "mac-1")
        let headers: HTTPFields = [.authorization: "Bearer \(token.raw)"]

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            try await body(
                World(
                    client: client, headers: headers, database: database, project: project,
                    user: user))
        }
    }

    private func pull(_ w: World, since: String? = nil, limit: Int? = nil) async throws
        -> SyncPullResponse
    {
        var query: [String] = []
        if let since {
            let encoded: String =
                since.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? since
            query.append("since=\(encoded)")
        }
        if let limit { query.append("limit=\(limit)") }
        let suffix: String = query.isEmpty ? "" : "?\(query.joined(separator: "&"))"

        return try await w.client.execute(
            uri: "/api/v1/sync/pull\(suffix)", method: .get, headers: w.headers
        ) { raw -> SyncPullResponse in
            #expect(raw.status == .ok)
            return try JSONCoders.decoder.decode(
                SyncPullResponse.self, from: Data(buffer: raw.body))
        }
    }

    /// First sync omits `since` entirely — the same endpoint, just a longer walk.
    @Test("a first sync returns everything with a watermark")
    func firstSyncReturnsEverything() async throws {
        try await withWorld { w in
            let page = try await self.pull(w)

            // The seeded user and project are both replicated entities.
            #expect(page.changes.count >= 2)
            #expect(page.nextWatermark.sequence > 0)
            #expect(page.hasMore == false)
        }
    }

    /// One unified stream: a client's replica needs Projects and Users to render an
    /// Issue at all, so they arrive through the same channel as everything else.
    @Test("the stream carries every replicated entity type")
    func streamCarriesEveryEntityType() async throws {
        try await withWorld { w in
            let issues = IssueRepository(database: w.database)
            let issue = try issues.create(
                Issue.fixture(key: nil, projectId: w.project.id, reporterId: w.user.id))
            try CommentRepository(database: w.database).save(
                Comment.fixture(issueId: issue.id, authorId: w.user.id))
            let labels = LabelRepository(database: w.database)
            let label = try labels.save(Label.fixture(projectId: w.project.id, name: "bug"))
            try labels.attach(labelId: label.id, to: issue.id, at: Date())

            let page = try await self.pull(w)
            let entities: Set<SyncEntity> = Set(page.changes.map { $0.entity })

            #expect(entities.contains(.user))
            #expect(entities.contains(.project))
            #expect(entities.contains(.issue))
            #expect(entities.contains(.comment))
            #expect(entities.contains(.label))
            #expect(entities.contains(.issueLabel))
        }
    }

    @Test("resuming from a watermark returns only what came after it")
    func resumingReturnsOnlyNewer() async throws {
        try await withWorld { w in
            let first = try await self.pull(w)
            let mark: String = first.nextWatermark.wireValue

            let issue = try IssueRepository(database: w.database).create(
                Issue.fixture(
                    key: nil, projectId: w.project.id, title: "Later", reporterId: w.user.id))

            let second = try await self.pull(w, since: mark)
            #expect(second.changes.count == 1)
            #expect(second.changes.first?.entity == .issue)
            #expect(second.changes.first?.id == issue.id.rawValue)
        }
    }

    /// Tombstones are first-class entries — the only way a delete propagates at all.
    @Test("a deleted entity arrives as a tombstone with no record")
    func tombstoneArrivesWithoutRecord() async throws {
        try await withWorld { w in
            let issues = IssueRepository(database: w.database)
            let issue = try issues.create(
                Issue.fixture(key: nil, projectId: w.project.id, reporterId: w.user.id))
            let mark: String = try await self.pull(w).nextWatermark.wireValue
            try issues.delete(issue.id, at: Date())

            let page = try await self.pull(w, since: mark)
            let change = try #require(page.changes.first)

            #expect(change.entity == .issue)
            #expect(change.deleted)
            #expect(change.record == nil, "a tombstone carried a record")
        }
    }

    /// Changes arrive in sequence order, which is what makes the watermark a
    /// resumable position rather than a hint.
    @Test("changes arrive in sequence order")
    func changesArriveInSequenceOrder() async throws {
        try await withWorld { w in
            let issues = IssueRepository(database: w.database)
            let mark: String = try await self.pull(w).nextWatermark.wireValue
            let first = try issues.create(
                Issue.fixture(
                    key: nil, projectId: w.project.id, title: "One", reporterId: w.user.id))
            let second = try issues.create(
                Issue.fixture(
                    key: nil, projectId: w.project.id, title: "Two", reporterId: w.user.id))

            let page = try await self.pull(w, since: mark)
            let ids: [UUID] = page.changes.map { $0.id }

            #expect(ids == [first.id.rawValue, second.id.rawValue])
        }
    }

    /// One upserted row per entity, not a history: an entity edited twice appears
    /// once, at its latest position. A history would return the same current record
    /// repeatedly, since convergence only cares about the endpoint.
    @Test("an entity edited twice appears once, at its latest position")
    func editedTwiceAppearsOnce() async throws {
        try await withWorld { w in
            let issues = IssueRepository(database: w.database)
            let issue = try issues.create(
                Issue.fixture(key: nil, projectId: w.project.id, reporterId: w.user.id))
            let mark: String = try await self.pull(w).nextWatermark.wireValue

            var patch = IssuePatch()
            patch.title = .set("Once")
            _ = try issues.apply(patch, to: issue.id, at: Date())
            patch.title = .set("Twice")
            _ = try issues.apply(patch, to: issue.id, at: Date())

            let page = try await self.pull(w, since: mark)
            #expect(page.changes.count == 1)
            guard case .issue(let record) = try #require(page.changes.first?.record) else {
                Testing.Issue.record("expected an issue record")
                return
            }
            #expect(record.title == "Twice")
        }
    }

    @Test("a page reports whether more remain, and following it drains the rest")
    func pagingDrainsEverything() async throws {
        try await withWorld { w in
            let issues = IssueRepository(database: w.database)
            for index in 1...5 {
                _ = try issues.create(
                    Issue.fixture(
                        key: nil, projectId: w.project.id, title: "Issue \(index)",
                        reporterId: w.user.id))
            }

            var seen: Int = 0
            var cursor: String?
            var pages: Int = 0
            var more: Bool = true
            while more && pages < 20 {
                let page = try await self.pull(w, since: cursor, limit: 2)
                seen += page.changes.count
                cursor = page.nextWatermark.wireValue
                more = page.hasMore
                pages += 1
            }

            // Seeded user and project, plus five issues.
            #expect(seen == 7)
            #expect(pages > 1, "everything arrived in one page, so paging was not exercised")
        }
    }

    /// After a restore the epoch changes, and a client presenting a stale one must be
    /// told to resync rather than silently receiving nothing forever.
    @Test("a watermark from a superseded epoch is refused as stale")
    func staleEpochIsRefused() async throws {
        try await withWorld { w in
            try await w.client.execute(
                uri: "/api/v1/sync/pull?since=someoldepoch%3A1", method: .get,
                headers: w.headers
            ) { raw in
                #expect(raw.status == .conflict)
                let problem = try JSONCoders.decoder.decode(
                    Problem.self, from: Data(buffer: raw.body))
                #expect(problem.type == Problem.staleEpochType)
            }
        }
    }

    @Test("a malformed watermark is refused")
    func malformedWatermarkIsRefused() async throws {
        try await withWorld { w in
            try await w.client.execute(
                uri: "/api/v1/sync/pull?since=nonsense", method: .get, headers: w.headers
            ) { raw in
                #expect(raw.status == .unprocessableContent)
            }
        }
    }

    @Test("pulling without credentials is unauthenticated")
    func pullRequiresCredentials() async throws {
        try await withWorld { w in
            try await w.client.execute(uri: "/api/v1/sync/pull", method: .get) { raw in
                #expect(raw.status == .unauthorized)
            }
        }
    }

    /// The client's own writes come back rather than being filtered by device: they
    /// return with authoritative timestamps and any normalisation, so a client that
    /// mis-tracked its own write self-heals.
    @Test("a client's own writes are echoed back rather than filtered out")
    func ownWritesAreEchoedBack() async throws {
        try await withWorld { w in
            let mark: String = try await self.pull(w).nextWatermark.wireValue

            let batch = SyncPush(
                deviceId: "mac-1",
                operations: [
                    .putIssue(
                        opId: UUID(), id: Issue.ID(), at: Date(),
                        body: IssueCreate(projectId: w.project.id, title: "Mine"))
                ])
            let data: Data = try JSONCoders.encoder.encode(batch)
            var pushHeaders: HTTPFields = w.headers
            pushHeaders[.contentType] = "application/json"

            try await w.client.execute(
                uri: "/api/v1/sync/push", method: .post, headers: pushHeaders,
                body: ByteBuffer(data: data)
            ) { raw in
                #expect(raw.status == .ok)
            }

            let page = try await self.pull(w, since: mark)
            #expect(page.changes.contains { $0.entity == .issue })
        }
    }
}
