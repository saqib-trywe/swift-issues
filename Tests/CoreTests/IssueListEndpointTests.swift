import Core
import Foundation
import Testing

@Suite("Issue list endpoint")
struct IssueListEndpointTests {

    private func query(_ request: HTTPRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: request.query.map { ($0.name, $0.value) })
    }

    @Test("lists at the collection path with an explicit default limit")
    func listsWithDefaultLimit() {
        let request = IssueEndpoints.list()

        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/issues")
        #expect(query(request)["limit"] == "50")
    }

    /// Comma-separated values are OR *within* a parameter. Written down because
    /// it is the kind of thing every caller would otherwise have to guess.
    @Test("multiple statuses are comma-joined into one parameter")
    func statusesAreOredWithinOneParameter() {
        let request = IssueEndpoints.list(
            filter: IssueFilter(statuses: [.todo, .inProgress]))

        #expect(query(request)["status"] == "todo,inProgress")
    }

    /// Separate parameters are AND-ed across.
    @Test("different criteria appear as separate parameters")
    func criteriaAreAndedAcrossParameters() throws {
        let request = IssueEndpoints.list(
            filter: IssueFilter(
                projectKey: try #require(ProjectKey("PROJ")),
                statuses: [.todo],
                priorities: [.high, .urgent],
                labels: ["bug", "backend"],
                query: "index"
            ))
        let parameters = query(request)

        #expect(parameters["projectKey"] == "PROJ")
        #expect(parameters["status"] == "todo")
        #expect(parameters["priority"] == "high,urgent")
        #expect(parameters["label"] == "bug,backend")
        #expect(parameters["q"] == "index")
    }

    /// `me` and `none` are the ergonomic wins ticket 06 called out for CLI and
    /// MCP, so they must not be mistaken for user ids.
    @Test("assignee accepts the me and none tokens as well as a user id")
    func assigneeTokens() {
        #expect(query(IssueEndpoints.list(filter: IssueFilter(assignee: .me)))["assignee"] == "me")
        #expect(
            query(IssueEndpoints.list(filter: IssueFilter(assignee: .unassigned)))["assignee"]
                == "none")

        let id = User.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000001")!)
        #expect(
            query(IssueEndpoints.list(filter: IssueFilter(assignee: .user(id))))["assignee"]
                == "018F3A9C-0000-7000-8000-000000000001")
    }

    @Test("updatedSince is sent as an RFC 3339 instant")
    func updatedSinceIsRFC3339() {
        let request = IssueEndpoints.list(
            filter: IssueFilter(updatedSince: Date(timeIntervalSince1970: 1_757_000_000.123)))

        #expect(query(request)["updatedSince"] == "2025-09-04T15:33:20.123Z")
    }

    @Test("descending sort is prefixed with a minus, ascending is bare")
    func sortDirection() {
        #expect(
            query(IssueEndpoints.list(sort: .updatedAt(descending: true)))["sort"]
                == "-updatedAt")
        #expect(
            query(IssueEndpoints.list(sort: .updatedAt(descending: false)))["sort"]
                == "updatedAt")
    }

    /// Cursors are opaque and never constructed by a caller — they only ever come
    /// back from a previous response.
    @Test("a cursor is passed through untouched")
    func cursorIsPassedThrough() {
        let request = IssueEndpoints.list(page: Pagination(cursor: "eyJzIjoxfQ", limit: 25))
        let parameters = query(request)

        #expect(parameters["cursor"] == "eyJzIjoxfQ")
        #expect(parameters["limit"] == "25")
    }

    /// Clamped rather than rejected: a caller asking for more than the server
    /// allows should get the maximum, not a failed round trip.
    @Test("limit is clamped to the documented maximum")
    func limitIsClamped() {
        #expect(query(IssueEndpoints.list(page: Pagination(limit: 5000)))["limit"] == "200")
        #expect(query(IssueEndpoints.list(page: Pagination(limit: 0)))["limit"] == "1")
    }

    @Test("a paginated response exposes its items and next cursor")
    func paginatedResponseDecodes() throws {
        let json = """
            {"items":["PROJ","OTHER"],"nextCursor":"eyJzIjoyfQ"}
            """

        let page = try JSONCoders.decoder.decode(
            Paginated<ProjectKey>.self, from: Data(json.utf8))

        #expect(page.items.count == 2)
        #expect(page.nextCursor == "eyJzIjoyfQ")
    }

    @Test("the last page has no next cursor")
    func lastPageHasNoCursor() throws {
        let page = try JSONCoders.decoder.decode(
            Paginated<ProjectKey>.self, from: Data(#"{"items":["PROJ"],"nextCursor":null}"#.utf8))

        #expect(page.nextCursor == nil)
    }
}
