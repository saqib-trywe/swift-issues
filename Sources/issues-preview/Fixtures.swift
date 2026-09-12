import AppCore
import AppViews
import ClientStore
import Core
import Foundation
import TestSupport

/// Sample data for the gallery. Nothing here is used by the apps.
enum Fixtures {
    static let projectId = Project.ID()
    static let assignee = User.fixture(email: "mel@example.com", displayName: "Mel Rowe")

    static let labels = [
        Core.Label.fixture(projectId: projectId, name: "bug", color: "#B5341B"),
        Core.Label.fixture(projectId: projectId, name: "sync", color: "#2D6CDF"),
    ]

    /// Every surface at once, which is how ticket 10's prototype settled the layout
    /// question in the first place.
    static var everySurface: SyncStatus {
        var status = SyncStatus()
        status.authentication = .needsReauthentication
        status.progress = .rebuilding
        status.queuedCount = 4
        status.needsAttention = [
            PendingOperation(
                sequence: 1,
                operation: .patchIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: Date(), body: IssuePatch()),
                state: .quarantined,
                problem: Problem(
                    type: "about:blank", title: "Invalid", status: 422,
                    detail: "A title may be at most 512 characters."),
                attemptCount: 2)
        ]
        status.lostToDeletion = [
            SupersededRecord(
                opId: UUID(),
                operation: .patchIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: Date(), body: IssuePatch()),
                current: nil, reason: .deletedElsewhere, occurredAt: Date())
        ]
        status.willOverwrite = [
            StaleEdit(
                operation: .patchIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: Date(), body: IssuePatch()),
                fields: [.title, .priority],
                editedAt: Date().addingTimeInterval(-259_200),
                serverChangedAt: Date().addingTimeInterval(-3_600))
        ]
        return status
    }

    struct Row {
        let issue: Overlaid<Issue>
        let labels: [Core.Label]
        let assignee: User?
    }

    /// One row per state a list has to render.
    static var rows: [Row] {
        [
            Row(
                issue: overlaid(
                    title: "Sync queue stalls behind a quarantined op",
                    status: .inProgress, priority: .urgent, key: IssueKey("PROJ-142"),
                    due: CivilDate(wireValue: "2026-12-25")),
                labels: labels, assignee: assignee),
            Row(
                issue: overlaid(
                    title: "Unsent edit, waiting to go out", priority: .high,
                    key: IssueKey("PROJ-141"), dirty: [.title, .priority]),
                labels: [], assignee: assignee),
            Row(
                issue: overlaid(
                    title: "Created on a plane — no key yet", key: nil, isUnsentCreate: true),
                labels: [labels[1]], assignee: nil),
            Row(
                issue: overlaid(
                    title: "Refused by the server", key: IssueKey("PROJ-139"),
                    dirty: [.title], isQuarantined: true),
                labels: [], assignee: assignee),
            Row(
                issue: overlaid(
                    title: "Deleted here, not yet confirmed", key: IssueKey("PROJ-138"),
                    isUnsentDelete: true),
                labels: [], assignee: nil),
            Row(
                issue: overlaid(
                    title: "Filed by an agent", key: IssueKey("PROJ-137"), via: .agent),
                labels: [labels[0]], assignee: nil),
            Row(
                issue: overlaid(
                    title: "Status this build does not recognise",
                    status: .unknown("triaged"), key: IssueKey("PROJ-136")),
                labels: [], assignee: nil),
        ]
    }

    static var progressStates: [(String, SyncStatus)] {
        [
            ("idle, nothing queued", status(progress: .idle, queued: 0)),
            ("idle, work queued", status(progress: .idle, queued: 3)),
            ("syncing", status(progress: .syncing, queued: 1)),
            ("rebuilding", status(progress: .rebuilding, queued: 0)),
            ("failed", status(progress: .failed("The server could not be reached."), queued: 2)),
        ]
    }

    private static func status(progress: SyncProgress, queued: Int) -> SyncStatus {
        var status = SyncStatus()
        status.progress = progress
        status.queuedCount = queued
        return status
    }

    private static func overlaid(
        title: String,
        status: Status = .todo,
        priority: Priority = .none,
        key: IssueKey? = nil,
        due: CivilDate? = nil,
        via: Via = .human,
        dirty: Set<IssueField> = [],
        isUnsentCreate: Bool = false,
        isUnsentDelete: Bool = false,
        isQuarantined: Bool = false
    ) -> Overlaid<Issue> {
        Overlaid(
            record: Core.Issue.fixture(
                key: key, projectId: projectId, title: title, status: status,
                priority: priority, dueDate: due, via: via),
            dirty: dirty,
            isUnsentCreate: isUnsentCreate,
            isUnsentDelete: isUnsentDelete,
            isQuarantined: isQuarantined)
    }
}
