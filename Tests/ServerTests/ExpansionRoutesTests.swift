import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import Synchronization
import TestSupport
import Testing

@testable import Server

/// Ticket 06's `expand`: opt-in, whitelisted, one level deep.
///
/// Without it a 50-row list view is an N+1; as a default it would bloat every
/// scripted call.
@Suite("Issue expansion")
struct ExpansionRoutesTests {

    private struct World: Sendable {
        let client: any TestClientProtocol
        let database: AppDatabase
        let token: String
        let owner: DomainUser
        let assignee: DomainUser
        let project: Project
        let issue: Core.Issue
        let label: Label
    }

    private func withWorld(_ body: @Sendable @escaping (World) async throws -> Void) async throws {
        let database = try AppDatabase.inMemory()
        let users = UserRepository(database: database)
        let owner = DomainUser.fixture(
            id: DomainUser.ID(), email: "owner@example.com", displayName: "Ada", role: .admin)
        let assignee = DomainUser.fixture(
            id: DomainUser.ID(), email: "mel@example.com", displayName: "Mel")
        try users.save(owner)
        try users.save(assignee)

        let project = Project.fixture(name: "Platform")
        try ProjectRepository(database: database).save(project)

        let issue = try IssueRepository(database: database).create(
            Core.Issue.fixture(
                key: nil, projectId: project.id, title: "Needs expanding",
                reporterId: owner.id, assigneeId: assignee.id))

        let labels = LabelRepository(database: database)
        let label = try labels.save(Label.fixture(projectId: project.id, name: "bug"))
        try labels.attach(labelId: label.id, to: issue.id, at: Date())

        let token = try SessionRepository(database: database).create(
            for: owner.id, kind: .human, deviceId: nil)

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            try await body(
                World(
                    client: client, database: database, token: token.raw, owner: owner,
                    assignee: assignee, project: project, issue: issue, label: label))
        }
    }

    private func get(_ w: World, _ uri: String) async throws -> (
        status: HTTPResponse.Status, body: String
    ) {
        try await w.client.execute(
            uri: uri, method: .get, headers: [.authorization: "Bearer \(w.token)"]
        ) { ($0.status, String(buffer: $0.body)) }
    }

    private func object(_ body: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    /// As a default it bloats every scripted call, so nothing is expanded unless
    /// asked for.
    @Test("nothing is expanded without the parameter")
    func nothingIsExpandedWithoutTheParameter() async throws {
        try await withWorld { w in
            let response = try await get(
                w, "/api/v1/issues/\(w.issue.id.rawValue.uuidString)")
            let payload = try object(response.body)

            #expect(response.status == .ok)
            #expect(payload["assignee"] == nil)
            #expect(payload["labels"] == nil)
            #expect(payload["assigneeId"] != nil)
        }
    }

    @Test(
        "each relationship expands",
        arguments: [
            ("assignee", "displayName", "Mel"),
            ("reporter", "displayName", "Ada"),
            ("project", "name", "Platform"),
        ])
    func eachRelationshipExpands(name: String, key: String, expected: String) async throws {
        try await withWorld { w in
            let response = try await get(
                w, "/api/v1/issues/\(w.issue.id.rawValue.uuidString)?expand=\(name)")
            let payload = try object(response.body)

            let expanded = try #require(payload[name] as? [String: Any])
            #expect(expanded[key] as? String == expected)
        }
    }

    @Test("labels expand as an array")
    func labelsExpandAsAnArray() async throws {
        try await withWorld { w in
            let response = try await get(
                w, "/api/v1/issues/\(w.issue.id.rawValue.uuidString)?expand=labels")
            let payload = try object(response.body)

            let labels = try #require(payload["labels"] as? [[String: Any]])
            #expect(labels.count == 1)
            #expect(labels[0]["name"] as? String == "bug")
        }
    }

    /// The expansion sits beside the id it resolves, so anything already decoding a
    /// plain Issue keeps working.
    @Test("an expanded response still decodes as a plain issue")
    func expandedResponseStillDecodesAsAPlainIssue() async throws {
        try await withWorld { w in
            let response = try await get(
                w, "/api/v1/issues/\(w.issue.id.rawValue.uuidString)?expand=assignee,labels")

            let plain = try JSONCoders.decoder.decode(
                Core.Issue.self, from: Data(response.body.utf8))
            #expect(plain.id == w.issue.id)
            #expect(plain.assigneeId == w.assignee.id)
        }
    }

    @Test("several expansions combine")
    func severalExpansionsCombine() async throws {
        try await withWorld { w in
            let response = try await get(
                w,
                "/api/v1/issues/\(w.issue.id.rawValue.uuidString)?expand=assignee,reporter,project,labels"
            )
            let payload = try object(response.body)

            #expect(payload["assignee"] != nil)
            #expect(payload["reporter"] != nil)
            #expect(payload["project"] != nil)
            #expect(payload["labels"] != nil)
        }
    }

    /// The reason expand exists at all.
    @Test("a list expands every row")
    func listExpandsEveryRow() async throws {
        try await withWorld { w in
            for index in 0..<5 {
                _ = try IssueRepository(database: w.database).create(
                    Core.Issue.fixture(
                        key: nil, projectId: w.project.id, title: "Issue \(index)",
                        reporterId: w.owner.id, assigneeId: w.assignee.id))
            }

            let response = try await get(w, "/api/v1/issues?expand=assignee")
            let page = try object(response.body)
            let items = try #require(page["items"] as? [[String: Any]])

            #expect(items.count == 6)
            #expect(items.allSatisfy { $0["assignee"] != nil })
        }
    }

    /// An unassigned issue expands to nothing rather than failing the whole page.
    @Test("an issue with no assignee expands without one")
    func issueWithNoAssigneeExpandsWithoutOne() async throws {
        try await withWorld { w in
            let unassigned = try IssueRepository(database: w.database).create(
                Core.Issue.fixture(
                    key: nil, projectId: w.project.id, title: "Nobody's",
                    reporterId: w.owner.id, assigneeId: nil))

            let response = try await get(
                w, "/api/v1/issues/\(unassigned.id.rawValue.uuidString)?expand=assignee")
            let payload = try object(response.body)

            #expect(response.status == .ok)
            #expect(payload["assignee"] == nil)
        }
    }

    /// Requested-and-none is a different answer from not-requested.
    @Test("an issue with no labels expands to an empty array, not an absent key")
    func issueWithNoLabelsExpandsToAnEmptyArray() async throws {
        try await withWorld { w in
            let bare = try IssueRepository(database: w.database).create(
                Core.Issue.fixture(
                    key: nil, projectId: w.project.id, title: "Unlabelled",
                    reporterId: w.owner.id))

            let response = try await get(
                w, "/api/v1/issues/\(bare.id.rawValue.uuidString)?expand=labels")
            let payload = try object(response.body)

            let labels = try #require(payload["labels"] as? [[String: Any]])
            #expect(labels.isEmpty)
        }
    }

    /// Silently expanding nothing would look identical to a server that does not
    /// support the relationship.
    @Test("an unknown expansion is refused, naming the known ones")
    func unknownExpansionIsRefused() async throws {
        try await withWorld { w in
            let response = try await get(
                w, "/api/v1/issues/\(w.issue.id.rawValue.uuidString)?expand=comments")

            #expect(response.status == .unprocessableContent)
            #expect(response.body.contains("assignee"))
        }
    }

    @Test("an unknown expansion is refused on a list too")
    func unknownExpansionIsRefusedOnAList() async throws {
        try await withWorld { w in
            let response = try await get(w, "/api/v1/issues?expand=nonsense")
            #expect(response.status == .unprocessableContent)
        }
    }

    /// A removed label must not reappear through expansion.
    @Test("a removed label is not expanded")
    func removedLabelIsNotExpanded() async throws {
        try await withWorld { w in
            try LabelRepository(database: w.database).detach(
                labelId: w.label.id, from: w.issue.id, at: Date())

            let response = try await get(
                w, "/api/v1/issues/\(w.issue.id.rawValue.uuidString)?expand=labels")
            let labels = try #require(try object(response.body)["labels"] as? [[String: Any]])

            #expect(labels.isEmpty)
        }
    }

    /// And neither must a deleted one.
    @Test("a deleted label is not expanded")
    func deletedLabelIsNotExpanded() async throws {
        try await withWorld { w in
            try LabelRepository(database: w.database).delete(w.label.id, at: Date())

            let response = try await get(
                w, "/api/v1/issues/\(w.issue.id.rawValue.uuidString)?expand=labels")
            let labels = try #require(try object(response.body)["labels"] as? [[String: Any]])

            #expect(labels.isEmpty)
        }
    }

    /// Expansion exists to remove an N+1, so resolving it row by row would
    /// reintroduce exactly the problem it was added to solve.
    ///
    /// The absolute count is uninteresting — each `read` costs a transaction as well
    /// as its statement — so what is asserted is that it does **not grow with the
    /// page**. A per-row implementation would fail this immediately.
    @Test("expanding costs the same whether the page is small or large")
    func expandingCostsTheSameWhateverThePageSize() async throws {
        func queriesToExpand(_ count: Int) async throws -> Int {
            // A Mutex rather than a captured var: the world's body is @Sendable.
            let measured = Mutex(0)
            try await withWorld { w in
                for index in 0..<count {
                    _ = try IssueRepository(database: w.database).create(
                        Core.Issue.fixture(
                            key: nil, projectId: w.project.id, title: "Issue \(index)",
                            reporterId: w.owner.id, assigneeId: w.assignee.id))
                }
                let issues = try IssueRepository(database: w.database)
                    .list(
                        filter: IssueFilter(), sort: nil, page: Pagination(limit: 200),
                        resolvingMeAs: w.owner.id
                    ).items

                // The in-memory database is a single connection, so a trace installed
                // here is still in place for the reads below.
                let counter = Mutex(0)
                try w.database.writer.write { db in
                    db.trace { _ in counter.withLock { $0 += 1 } }
                }
                _ = try IssueExpansion(database: w.database)
                    .expand(issues, with: Expansion.allCases)
                measured.withLock { $0 = counter.withLock { $0 } }
            }
            return measured.withLock { $0 }
        }

        let small = try await queriesToExpand(1)
        let large = try await queriesToExpand(40)

        #expect(
            small == large,
            Comment(rawValue: "1 issue took \(small) queries, 41 took \(large) — it scales with the page"))
    }
}
