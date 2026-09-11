import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Server

private typealias Issue = Core.Issue

@Suite("Issue listing and filters")
struct IssueListingTests {

    private struct World {
        let database: AppDatabase
        let issues: IssueRepository
        let project: Project
        let other: Project
        let me: User
        let them: User
    }

    private func world() throws -> World {
        let database = try AppDatabase.inMemory()
        let users = UserRepository(database: database)
        let me = User.fixture(email: "me@example.com")
        let them = User.fixture(email: "them@example.com")
        try users.save(me)
        try users.save(them)
        let projects = ProjectRepository(database: database)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        let other = Project.fixture(id: Project.ID(), key: ProjectKey("OTHER")!)
        try projects.save(project)
        try projects.save(other)
        return World(
            database: database, issues: IssueRepository(database: database),
            project: project, other: other, me: me, them: them)
    }

    @discardableResult
    private func add(
        _ w: World, in project: Project? = nil, title: String, description: String = "",
        status: Status = .todo, priority: Priority = .none, assignee: User? = nil,
        updatedAt: Date = Date()
    ) throws -> Issue {
        var draft = Issue.fixture(
            key: nil, projectId: (project ?? w.project).id, title: title,
            description: description, status: status, priority: priority,
            reporterId: w.me.id, assigneeId: assignee?.id)
        draft.updatedAt = updatedAt
        return try w.issues.create(draft)
    }

    private func titles(_ page: Paginated<Issue>) -> Set<String> {
        Set(page.items.map(\.title))
    }

    // MARK: Filters

    /// Values within one field are OR-ed.
    @Test("multiple statuses match any of them")
    func statusesAreOred() throws {
        let w = try world()
        try add(w, title: "Todo", status: .todo)
        try add(w, title: "Doing", status: .inProgress)
        try add(w, title: "Done", status: .done)

        let page = try w.issues.list(
            filter: IssueFilter(statuses: [.todo, .inProgress]), sort: nil,
            page: Pagination(), resolvingMeAs: w.me.id)

        #expect(titles(page) == ["Todo", "Doing"])
    }

    /// Different fields are AND-ed.
    @Test("separate criteria narrow rather than widen")
    func criteriaAreAnded() throws {
        let w = try world()
        try add(w, title: "Match", status: .todo, priority: .urgent)
        try add(w, title: "Wrong status", status: .done, priority: .urgent)
        try add(w, title: "Wrong priority", status: .todo, priority: .low)

        let page = try w.issues.list(
            filter: IssueFilter(statuses: [.todo], priorities: [.urgent]), sort: nil,
            page: Pagination(), resolvingMeAs: w.me.id)

        #expect(titles(page) == ["Match"])
    }

    @Test("filtering by project key confines results to that project")
    func projectKeyConfines() throws {
        let w = try world()
        try add(w, title: "Mine")
        try add(w, in: w.other, title: "Theirs")

        let page = try w.issues.list(
            filter: IssueFilter(projectKey: ProjectKey("PROJ")), sort: nil,
            page: Pagination(), resolvingMeAs: w.me.id)

        #expect(titles(page) == ["Mine"])
    }

    /// `me` and `none` are the ergonomic tokens ticket 06 added for CLI and MCP.
    @Test("assignee filtering handles me, nobody and a specific user")
    func assigneeFiltering() throws {
        let w = try world()
        try add(w, title: "Mine", assignee: w.me)
        try add(w, title: "Theirs", assignee: w.them)
        try add(w, title: "Nobody")

        func titlesFor(_ assignee: AssigneeFilter) throws -> Set<String> {
            titles(
                try w.issues.list(
                    filter: IssueFilter(assignee: assignee), sort: nil, page: Pagination(),
                    resolvingMeAs: w.me.id))
        }

        #expect(try titlesFor(.me) == ["Mine"])
        #expect(try titlesFor(.unassigned) == ["Nobody"])
        #expect(try titlesFor(.user(w.them.id)) == ["Theirs"])
    }

    @Test("labels filter by name and match any of them")
    func labelFiltering() throws {
        let w = try world()
        let tagged = try add(w, title: "Tagged")
        try add(w, title: "Untagged")

        let labels = LabelRepository(database: w.database)
        let bug = try labels.save(
            Label.fixture(projectId: w.project.id, name: "bug"))
        try labels.attach(labelId: bug.id, to: tagged.id, at: Date())

        let page = try w.issues.list(
            filter: IssueFilter(labels: ["bug"]), sort: nil, page: Pagination(),
            resolvingMeAs: w.me.id)

        #expect(titles(page) == ["Tagged"])
    }

    /// A removed label must stop matching: membership is a tombstoned link, and a
    /// filter that ignored the tombstone would keep returning it.
    @Test("a removed label stops matching")
    func removedLabelStopsMatching() throws {
        let w = try world()
        let tagged = try add(w, title: "Tagged")
        let labels = LabelRepository(database: w.database)
        let bug = try labels.save(Label.fixture(projectId: w.project.id, name: "bug"))
        try labels.attach(labelId: bug.id, to: tagged.id, at: Date())
        try labels.detach(labelId: bug.id, from: tagged.id, at: Date())

        let page = try w.issues.list(
            filter: IssueFilter(labels: ["bug"]), sort: nil, page: Pagination(),
            resolvingMeAs: w.me.id)

        #expect(page.items.isEmpty)
    }

    @Test("free text matches title or description, case-insensitively")
    func freeTextSearch() throws {
        let w = try world()
        try add(w, title: "Partial index", description: "")
        try add(w, title: "Unrelated", description: "needs a partial INDEX here")
        try add(w, title: "Nothing", description: "")

        let page = try w.issues.list(
            filter: IssueFilter(query: "partial"), sort: nil, page: Pagination(),
            resolvingMeAs: w.me.id)

        #expect(titles(page) == ["Partial index", "Unrelated"])
    }

    @Test("updatedSince excludes anything older")
    func updatedSinceFilters() throws {
        let w = try world()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date(timeIntervalSince1970: 1_757_000_000)
        try add(w, title: "Old", updatedAt: old)
        try add(w, title: "Recent", updatedAt: recent)

        let page = try w.issues.list(
            filter: IssueFilter(updatedSince: old.addingTimeInterval(1)), sort: nil,
            page: Pagination(), resolvingMeAs: w.me.id)

        #expect(titles(page) == ["Recent"])
    }

    @Test("tombstoned issues never appear")
    func tombstonesExcluded() throws {
        let w = try world()
        let doomed = try add(w, title: "Doomed")
        try add(w, title: "Alive")
        try w.issues.delete(doomed.id, at: Date())

        let page = try w.issues.list(
            filter: IssueFilter(), sort: nil, page: Pagination(), resolvingMeAs: w.me.id)

        #expect(titles(page) == ["Alive"])
    }

    // MARK: Ordering and pagination

    @Test("descending and ascending order are both honoured")
    func sortDirection() throws {
        let w = try world()
        try add(w, title: "First", updatedAt: Date(timeIntervalSince1970: 1_000))
        try add(w, title: "Second", updatedAt: Date(timeIntervalSince1970: 2_000))

        let descending = try w.issues.list(
            filter: IssueFilter(), sort: .updatedAt(descending: true), page: Pagination(),
            resolvingMeAs: w.me.id)
        #expect(descending.items.map(\.title) == ["Second", "First"])

        let ascending = try w.issues.list(
            filter: IssueFilter(), sort: .updatedAt(descending: false), page: Pagination(),
            resolvingMeAs: w.me.id)
        #expect(ascending.items.map(\.title) == ["First", "Second"])
    }

    @Test("a page returns a cursor, and following it returns the remainder exactly once")
    func cursorWalksEveryRowOnce() throws {
        let w = try world()
        for index in 1...5 {
            try add(
                w, title: "Issue \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
        }

        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try w.issues.list(
                filter: IssueFilter(), sort: .updatedAt(descending: true),
                page: Pagination(cursor: cursor, limit: 2), resolvingMeAs: w.me.id)
            seen.append(contentsOf: page.items.map(\.title))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(seen == ["Issue 5", "Issue 4", "Issue 3", "Issue 2", "Issue 1"])
        #expect(Set(seen).count == seen.count, "a row was returned twice")
    }

    @Test("the last page carries no cursor")
    func lastPageHasNoCursor() throws {
        let w = try world()
        try add(w, title: "Only")

        let page = try w.issues.list(
            filter: IssueFilter(), sort: nil, page: Pagination(limit: 50),
            resolvingMeAs: w.me.id)

        #expect(page.nextCursor == nil)
    }

    /// The entire reason ticket 06 chose cursors over offsets: rows are created and
    /// deleted while a client is paging, and offset paging silently skips and
    /// duplicates. Nothing already listed may be lost or repeated.
    @Test("inserting a row mid-scan neither skips nor duplicates the rest")
    func insertionMidScanIsStable() throws {
        let w = try world()
        for index in 1...4 {
            try add(
                w, title: "Issue \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index * 1_000)))
        }

        let first = try w.issues.list(
            filter: IssueFilter(), sort: .updatedAt(descending: true),
            page: Pagination(limit: 2), resolvingMeAs: w.me.id)
        #expect(first.items.map(\.title) == ["Issue 4", "Issue 3"])

        // A newer issue arrives between pages — it sorts ahead of everything, so it
        // belongs on a page the client has already passed.
        try add(w, title: "Interloper", updatedAt: Date(timeIntervalSince1970: 9_000))

        let second = try w.issues.list(
            filter: IssueFilter(), sort: .updatedAt(descending: true),
            page: Pagination(cursor: first.nextCursor, limit: 2), resolvingMeAs: w.me.id)

        #expect(
            second.items.map(\.title) == ["Issue 2", "Issue 1"],
            "the second page skipped or repeated a row")
    }
}

@Suite("Label membership reads")
struct LabelMembershipTests {

    /// Membership is removed by tombstoning the link, so a read that ignored the
    /// tombstone would keep reporting a label that was taken off.
    @Test("live label ids exclude removed ones")
    func liveLabelIdsExcludeRemoved() throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture()
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let issue = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, reporterId: user.id))

        let labels = LabelRepository(database: database)
        let kept = try labels.save(Label.fixture(projectId: project.id, name: "bug"))
        let removed = try labels.save(Label.fixture(projectId: project.id, name: "ux"))
        try labels.attach(labelId: kept.id, to: issue.id, at: Date())
        try labels.attach(labelId: removed.id, to: issue.id, at: Date())
        try labels.detach(labelId: removed.id, from: issue.id, at: Date())

        #expect(try labels.labelIds(for: issue.id) == [kept.id])
    }

    /// Re-attaching revives the link rather than failing, which is what a replayed
    /// offline operation needs.
    @Test("re-attaching a removed label revives it")
    func reattachingRevives() throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture()
        try UserRepository(database: database).save(user)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        try ProjectRepository(database: database).save(project)
        let issue = try IssueRepository(database: database).create(
            Issue.fixture(key: nil, projectId: project.id, reporterId: user.id))

        let labels = LabelRepository(database: database)
        let bug = try labels.save(Label.fixture(projectId: project.id, name: "bug"))
        try labels.attach(labelId: bug.id, to: issue.id, at: Date())
        try labels.detach(labelId: bug.id, from: issue.id, at: Date())
        try labels.attach(labelId: bug.id, to: issue.id, at: Date())

        #expect(try labels.labelIds(for: issue.id) == [bug.id])
    }
}
