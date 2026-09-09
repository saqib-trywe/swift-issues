import Core
import Foundation
import Testing

@Suite("Issue write endpoints")
struct IssueWriteEndpointTests {

    private let issueId = Core.Issue.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000020")!)
    private let projectId = Project.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000002")!)
    private let userId = User.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000001")!)

    private func object(_ request: HTTPRequest) throws -> [String: Any] {
        let body = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// PUT with a caller-supplied id, not POST: an offline client retrying a
    /// create it never saw a response to must not produce two issues. See ADR 0005.
    @Test("creating uses PUT at the caller-supplied id")
    func createUsesPUT() throws {
        let request = try IssueEndpoints.create(
            id: issueId, IssueCreate(projectId: projectId, title: "Add a partial index"))

        #expect(request.method == "PUT")
        #expect(request.path == "/api/v1/issues/018F3A9C-0000-7000-8000-000000000020")

        let body = try object(request)
        #expect(body["title"] as? String == "Add a partial index")
        #expect(body["status"] as? String == "todo")
        #expect(body["priority"] as? String == "none")
    }

    /// The whole reason Patchable exists: a field nobody touched must not appear
    /// in the payload at all, or the server reads its absence as a value.
    @Test("a patch omits every field the caller did not set")
    func patchOmitsUntouchedFields() throws {
        var patch = IssuePatch()
        patch.title = .set("Renamed")

        let body = try object(try IssueEndpoints.patch(id: issueId, patch))

        #expect(body.keys.sorted() == ["title"])
        #expect(body["title"] as? String == "Renamed")
    }

    /// Clearing is distinct from omitting. Without this an assignee could never
    /// be removed.
    @Test("clearing a nullable field sends an explicit null")
    func clearingSendsNull() throws {
        var patch = IssuePatch()
        patch.assigneeId = .cleared
        patch.dueDate = .cleared

        let body = try object(try IssueEndpoints.patch(id: issueId, patch))

        #expect(body.keys.sorted() == ["assigneeId", "dueDate"])
        #expect(body["assigneeId"] is NSNull)
        #expect(body["dueDate"] is NSNull)
    }

    @Test("setting a nullable field sends the value")
    func settingSendsValue() throws {
        var patch = IssuePatch()
        patch.assigneeId = .set(userId)
        patch.dueDate = .set(CivilDate(year: 2026, month: 9, day: 11)!)

        let body = try object(try IssueEndpoints.patch(id: issueId, patch))

        #expect(body["assigneeId"] as? String == "018F3A9C-0000-7000-8000-000000000001")
        #expect(body["dueDate"] as? String == "2026-09-11")
    }

    @Test("a patch reports whether it would change anything")
    func patchReportsEmptiness() {
        #expect(IssuePatch().isEmpty)

        var patch = IssuePatch()
        patch.status = .set(.done)
        #expect(patch.isEmpty == false)
    }

    /// Label membership is mutated as a delta, so two people adding different
    /// labels concurrently both survive. The link records themselves stay
    /// internal to sync. See ADR 0003 and ticket 06.
    @Test("label membership is changed with an add and remove delta")
    func labelsUseADelta() throws {
        let bug = Label.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000003")!)
        let stale = Label.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-0000000000AA")!)

        let request = try IssueEndpoints.changeLabels(id: issueId, add: [bug], remove: [stale])

        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v1/issues/018F3A9C-0000-7000-8000-000000000020/labels")

        let body = try object(request)
        #expect((body["add"] as? [String])?.first == "018F3A9C-0000-7000-8000-000000000003")
        #expect((body["remove"] as? [String])?.first == "018F3A9C-0000-7000-8000-0000000000AA")
    }
}
