import AppCore
import AppViews
import ClientStore
import Core
import Foundation
import TestSupport

/// Sample data for the gallery. Nothing here is used by the apps.
enum Fixtures {

    /// Fills a replica with something to look at.
    ///
    /// Takes the directory so it can target the Mac app's sandbox container or a
    /// simulator's — a sandboxed app reads its preferences and Keychain from its
    /// own container, so the replica is the one thing reachable from outside.
    static func seedContainerReplica(at directory: URL? = nil) throws {
        if let directory { try seed(into: directory); return }
        try seed(
            into: FileManager.default.homeDirectoryForCurrentUser
                .appending(
                    path: "Library/Containers/co.trywe.issues/Data/Library/Application Support/Issues"
                ))
    }

    private static func seed(into container: URL) throws {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let database = try ReplicaDatabase.open(at: container.appending(path: "replica.sqlite"))
        let projectId = Project.ID(UUIDv7.generate())
        let reporter = User.ID(UUIDv7.generate())

        let project = Project(
            id: projectId, key: ProjectKey("PLAT")!, name: "Platform",
            description: "Server and sync work", archived: false,
            createdAt: Date(), updatedAt: Date())

        func issue(_ number: Int, _ title: String, _ status: Status, _ priority: Priority) -> Issue {
            Issue(
                id: Issue.ID(UUIDv7.generate()), key: IssueKey("PLAT-\(number)"), projectId: projectId,
                title: title, description: "", status: status, priority: priority,
                reporterId: reporter, via: .human, createdAt: Date(), updatedAt: Date())
        }

        let seeded: [Issue] = [
            issue(1, "Sync queue stalls behind a quarantined op", .inProgress, .urgent),
            issue(2, "Tighten the epoch watermark check", .todo, .high),
            issue(3, "Archive old projects", .done, .none),
        ]

        try database.apply(
            [SyncChange(entity: .project, id: projectId.rawValue, deleted: false, record: .project(project))]
                + seeded.map {
                    SyncChange(entity: .issue, id: $0.id.rawValue, deleted: false, record: .issue($0))
                },
            upTo: Watermark(epoch: "seed", sequence: 10)!)

        // A locally created issue, to show the unsent state.
        let writer = IssueWriter(database: database)
        _ = try writer.create(
            IssueDraft(title: "Written offline, not yet sent", priority: .medium), in: projectId)

        print("seeded \(try database.issues(in: projectId).count) issues")
    }

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

    static let reporter = User.fixture(email: "ada@example.com", displayName: "Ada Cole")

    static func authorName(_ id: User.ID) -> String? {
        id == assignee.id ? assignee.displayName : reporter.displayName
    }

    /// An issue with everything the detail view has to cope with at once: an
    /// unrecognised status, an unsent edit, and a description using every block.
    static var detailIssue: Overlaid<Issue> {
        Overlaid(
            record: Core.Issue.fixture(
                key: IssueKey("PROJ-142"), projectId: projectId,
                title: "Sync queue stalls behind a quarantined op",
                description: """
                    The queue stops making progress once an operation is refused.

                    ## Steps

                    1. Queue a write the server will reject
                    2. Push
                    3. Queue an unrelated write

                    The unrelated write never goes out. Expected **only** dependents
                    to be held back.

                    ```
                    SQLite error 1: no such column: sequence
                        at PendingOperation.swift:118
                    ```

                    > Reported by Mel on the beta build.
                    """,
                status: .unknown("triaged"), priority: .urgent,
                reporterId: reporter.id, assigneeId: assignee.id,
                dueDate: CivilDate(wireValue: "2026-12-25")),
            dirty: [.priority])
    }

    static var thread: [Core.Comment] {
        [
            Core.Comment.fixture(
                authorId: reporter.id,
                body: "Reproduced on `main`. It is the partial index — see above."),
            Core.Comment.fixture(authorId: assignee.id, body: nil),
            Core.Comment.fixture(
                authorId: assignee.id, body: "Fix pushed.", via: .agent),
        ]
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
