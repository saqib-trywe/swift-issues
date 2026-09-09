import Core
import Foundation
import Testing

@Suite("Issue endpoints")
struct IssueEndpointTests {

    private let id = Core.Issue.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000020")!)

    @Test("fetching by id addresses the resource by UUID")
    func fetchByID() {
        let request = IssueEndpoints.get(.id(id))

        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/issues/018F3A9C-0000-7000-8000-000000000020")
        #expect(request.body == nil)
    }

    /// Humans and agents hold keys, not UUIDs. Without key addressing every CLI
    /// and MCP call needs a lookup round trip first. See ticket 06.
    @Test("fetching by Issue Key addresses the resource by key")
    func fetchByKey() throws {
        let request = IssueEndpoints.get(.key(try #require(IssueKey("PROJ-142"))))

        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/issues/PROJ-142")
    }

    /// Unexpanded, a list view is an N+1: it has no label names or colours to
    /// render. Expansion is opt-in so scripted callers do not pay for it.
    @Test("expansion is opt-in and comma-joined")
    func expansionIsOptIn() {
        let plain = IssueEndpoints.get(.id(id))
        #expect(plain.query.isEmpty)

        let expanded = IssueEndpoints.get(.id(id), expand: [.labels, .assignee])
        #expect(expanded.query.contains { $0.name == "expand" && $0.value == "labels,assignee" })
    }

    @Test("deleting addresses the resource by id and sends no body")
    func deleteByID() {
        let request = IssueEndpoints.delete(id)

        #expect(request.method == "DELETE")
        #expect(request.path == "/api/v1/issues/018F3A9C-0000-7000-8000-000000000020")
        #expect(request.body == nil)
    }
}
