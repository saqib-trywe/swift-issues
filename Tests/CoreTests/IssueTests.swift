import Core
import Foundation
import Testing

// Swift Testing exports its own `Issue`, so the domain type is aliased here.
private typealias Issue = Core.Issue

@Suite("Issue")
struct IssueTests {

    private func decode(_ json: String) throws -> Issue {
        try JSONCoders.decoder.decode(Issue.self, from: Data(json.utf8))
    }

    @Test("decodes a fully populated issue from the wire shape in ticket 06")
    func decodesFullyPopulatedIssue() throws {
        let issue = try decode(
            """
            {
              "id": "018f3a9c-0000-7000-8000-000000000020",
              "key": "PROJ-142",
              "projectId": "018f3a9c-0000-7000-8000-000000000002",
              "title": "Sync queue stalls behind a quarantined op",
              "description": "A rejected op blocks its dependents.",
              "status": "inProgress",
              "priority": "urgent",
              "reporterId": "018f3a9c-0000-7000-8000-000000000001",
              "assigneeId": "018f3a9c-0000-7000-8000-000000000001",
              "dueDate": "2026-09-11",
              "via": "human",
              "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """)

        #expect(issue.key == IssueKey("PROJ-142"))
        #expect(issue.status == .inProgress)
        #expect(issue.priority == .urgent)
        #expect(issue.dueDate == CivilDate(year: 2026, month: 9, day: 11))
        #expect(issue.assigneeId != nil)
    }

    /// An Issue created offline has no key until the server assigns one on first
    /// sync, so every list and detail view needs a placeholder state. See ADR 0003.
    @Test("an unsynced issue has no key")
    func unsyncedIssueHasNoKey() throws {
        let issue = try decode(
            """
            {
              "id": "018f3a9c-0000-7000-8000-000000000021",
              "key": null,
              "projectId": "018f3a9c-0000-7000-8000-000000000002",
              "title": "Draft: label picker loses colour on rename",
              "description": "", "status": "todo", "priority": "none",
              "reporterId": "018f3a9c-0000-7000-8000-000000000001",
              "assigneeId": null, "dueDate": null, "via": "human", "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """)

        #expect(issue.key == nil)
        #expect(issue.assigneeId == nil)
        #expect(issue.dueDate == nil)
    }

    /// Priority defaults to none deliberately: a tracker where everything is born
    /// "medium" teaches people that priority is noise. See CONTEXT.md.
    @Test("an unassigned, unprioritised issue is representable")
    func unprioritisedIssueIsRepresentable() throws {
        let issue = try decode(
            """
            {
              "id": "018f3a9c-0000-7000-8000-000000000022", "key": "PROJ-131",
              "projectId": "018f3a9c-0000-7000-8000-000000000002",
              "title": "Rename Workspace to Instance everywhere",
              "description": "", "status": "cancelled", "priority": "none",
              "reporterId": "018f3a9c-0000-7000-8000-000000000001",
              "assigneeId": null, "dueDate": null, "via": "human", "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """)

        #expect(issue.priority == .none)
        #expect(issue.status.category == .closed)
    }

    @Test("a status this build does not recognise is preserved, not rejected")
    func unknownStatusIsPreserved() throws {
        let issue = try decode(
            """
            {
              "id": "018f3a9c-0000-7000-8000-000000000023", "key": "PROJ-150",
              "projectId": "018f3a9c-0000-7000-8000-000000000002",
              "title": "Filed by a newer server", "description": "",
              "status": "triaged", "priority": "none",
              "reporterId": "018f3a9c-0000-7000-8000-000000000001",
              "assigneeId": null, "dueDate": null, "via": "human", "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """)

        #expect(issue.status == .unknown("triaged"))
        #expect(issue.status.category == nil)
    }

    /// Nothing is hard-deleted: to a syncing client an absent row and a
    /// never-seen row are indistinguishable, so a deleted Issue is a tombstone.
    @Test("a tombstoned issue reports itself deleted")
    func tombstonedIssueReportsDeleted() throws {
        let live = try decode(
            """
            {
              "id": "018f3a9c-0000-7000-8000-000000000024", "key": "PROJ-160",
              "projectId": "018f3a9c-0000-7000-8000-000000000002",
              "title": "Live", "description": "", "status": "todo", "priority": "none",
              "reporterId": "018f3a9c-0000-7000-8000-000000000001",
              "assigneeId": null, "dueDate": null, "via": "human", "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """)
        let tombstoned = try decode(
            """
            {
              "id": "018f3a9c-0000-7000-8000-000000000025", "key": "PROJ-161",
              "projectId": "018f3a9c-0000-7000-8000-000000000002",
              "title": "Gone", "description": "", "status": "todo", "priority": "none",
              "reporterId": "018f3a9c-0000-7000-8000-000000000001",
              "assigneeId": null, "dueDate": null, "via": "human",
              "deletedAt": "2025-09-05T09:00:00.000Z",
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-05T09:00:00.000Z"
            }
            """)

        #expect(live.isDeleted == false)
        #expect(tombstoned.isDeleted)
    }
}
