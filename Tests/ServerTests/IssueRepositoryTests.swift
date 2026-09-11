import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Server

// Swift Testing exports its own `Issue`.
private typealias Issue = Core.Issue

@Suite("Issue repository")
struct IssueRepositoryTests {

    private struct Fixture {
        let database: AppDatabase
        let issues: IssueRepository
        let project: Project
        let other: Project
        let user: User
    }

    private func fixture() throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let user = User.fixture()
        try UserRepository(database: database).save(user)
        let projects = ProjectRepository(database: database)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        let other = Project.fixture(id: Project.ID(), key: ProjectKey("OTHER")!)
        try projects.save(project)
        try projects.save(other)
        return Fixture(
            database: database, issues: IssueRepository(database: database),
            project: project, other: other, user: user)
    }

    private func draft(_ f: Fixture, in project: Project? = nil, title: String = "A title")
        -> Issue
    {
        Issue.fixture(
            key: nil, projectId: (project ?? f.project).id, title: title,
            reporterId: f.user.id)
    }

    /// The server assigns the Issue Key on first write; the client's copy has none
    /// until then, which is why it is optional all the way through.
    @Test("creating an issue assigns the next key in its project")
    func createAssignsAKey() throws {
        let f = try fixture()

        let created = try f.issues.create(draft(f))

        #expect(created.key == IssueKey("PROJ-1"))
    }

    @Test("key numbering is per project, not global")
    func keyNumberingIsPerProject() throws {
        let f = try fixture()

        let first = try f.issues.create(draft(f))
        let second = try f.issues.create(draft(f, in: f.other))

        #expect(first.key == IssueKey("PROJ-1"))
        #expect(second.key == IssueKey("OTHER-1"))
    }

    /// Keys are never reused, even after deletion: reuse would silently repoint
    /// every old reference — commit trailers, chat messages — at a different Issue.
    @Test("a deleted issue burns its number rather than freeing it")
    func deletedKeysAreNeverReused() throws {
        let f = try fixture()
        let first = try f.issues.create(draft(f))
        try f.issues.delete(first.id, at: Date())

        let second = try f.issues.create(draft(f))

        #expect(first.key == IssueKey("PROJ-1"))
        #expect(second.key == IssueKey("PROJ-2"), "a burned number was handed out again")
    }

    @Test("every mutable field starts with a timestamp")
    func creationStampsEveryMutableField() throws {
        let f = try fixture()

        let created = try f.issues.create(draft(f))
        let stamps = try f.issues.fieldTimestamps(created.id)

        for field in ["title", "description", "status", "priority", "assignee_id", "due_date"] {
            #expect(stamps[field] != nil, "missing stamp for \(field)")
        }
    }

    /// Per-field last-write-wins depends on this: only the fields a patch names
    /// may advance, or an untouched field would start winning conflicts it never
    /// participated in.
    @Test("a patch stamps only the fields it names")
    func patchStampsOnlyNamedFields() throws {
        let f = try fixture()
        let created = try f.issues.create(draft(f))
        let before = try f.issues.fieldTimestamps(created.id)

        var patch = IssuePatch()
        patch.status = .set(.inProgress)
        let later = Date().addingTimeInterval(60)
        _ = try f.issues.apply(patch, to: created.id, at: later)

        let after = try f.issues.fieldTimestamps(created.id)
        #expect(after["status"] != before["status"])
        #expect(after["title"] == before["title"], "an unnamed field's stamp moved")
        #expect(after["priority"] == before["priority"])
    }

    @Test("a patch applies the values it names and leaves the rest")
    func patchAppliesNamedValues() throws {
        let f = try fixture()
        let created = try f.issues.create(draft(f, title: "Keep me"))

        var patch = IssuePatch()
        patch.priority = .set(.urgent)
        let updated = try f.issues.apply(patch, to: created.id, at: Date())

        #expect(updated?.priority == .urgent)
        #expect(updated?.title == "Keep me")
    }

    /// Clearing is distinct from omitting, all the way to the column.
    @Test("clearing a nullable field nulls it, and omitting leaves it")
    func clearingNullsTheColumn() throws {
        let f = try fixture()
        var seed = draft(f)
        seed.assigneeId = f.user.id
        seed.dueDate = CivilDate(year: 2026, month: 9, day: 11)
        let created = try f.issues.create(seed)

        var clearAssignee = IssuePatch()
        clearAssignee.assigneeId = .cleared
        let updated = try f.issues.apply(clearAssignee, to: created.id, at: Date())

        #expect(updated?.assigneeId == nil)
        #expect(updated?.dueDate == CivilDate(year: 2026, month: 9, day: 11), "dueDate was cleared")
    }

    @Test("every field survives a round trip through the database")
    func fieldsSurviveRoundTrip() throws {
        let f = try fixture()
        var seed = draft(f, title: "Sync stalls")
        seed.description = "A rejected op blocks its dependents."
        seed.status = .inProgress
        seed.priority = .urgent
        seed.assigneeId = f.user.id
        seed.dueDate = CivilDate(year: 2026, month: 9, day: 11)

        let created = try f.issues.create(seed)
        let loaded = try f.issues.find(created.id)

        #expect(loaded?.title == "Sync stalls")
        #expect(loaded?.status == .inProgress)
        #expect(loaded?.priority == .urgent)
        #expect(loaded?.assigneeId == f.user.id)
        #expect(loaded?.dueDate == CivilDate(year: 2026, month: 9, day: 11))
        #expect(loaded?.via == .human)
    }

    /// Humans and agents hold keys, not UUIDs, so the server has to resolve them.
    @Test("an issue can be found by its key as well as its id")
    func findableByKey() throws {
        let f = try fixture()
        let created = try f.issues.create(draft(f))

        #expect(try f.issues.find(key: IssueKey("PROJ-1")!)?.id == created.id)
        #expect(try f.issues.find(key: IssueKey("PROJ-99")!) == nil)
    }

    /// Nothing is hard-deleted: an absent row and a never-seen row are
    /// indistinguishable to a syncing client, so deletes would resurrect.
    @Test("deleting tombstones the row rather than removing it")
    func deleteTombstones() throws {
        let f = try fixture()
        let created = try f.issues.create(draft(f))

        try f.issues.delete(created.id, at: Date())

        let loaded = try f.issues.find(created.id)
        #expect(loaded?.isDeleted == true, "the row should still be there, tombstoned")

        let rows = try f.database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue") ?? 0
        }
        #expect(rows == 1)
    }

    @Test("creating, patching and deleting each advance the change cursor")
    func mutationsAdvanceTheCursor() throws {
        let f = try fixture()

        func sequence() throws -> Int {
            try f.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM change_cursor") ?? 0
            }
        }

        let afterProjects = try sequence()
        let created = try f.issues.create(draft(f))
        let afterCreate = try sequence()
        #expect(afterCreate > afterProjects)

        var patch = IssuePatch()
        patch.title = .set("Renamed")
        _ = try f.issues.apply(patch, to: created.id, at: Date())
        let afterPatch = try sequence()
        #expect(afterPatch > afterCreate)

        try f.issues.delete(created.id, at: Date())
        #expect(try sequence() > afterPatch)
    }

    /// Ticket 08: the server strictly rejects a reference to an id it has not
    /// seen, rather than accepting a dangling one and reaping it later.
    @Test("creating an issue in a project that does not exist is rejected")
    func createInUnknownProjectIsRejected() throws {
        let f = try fixture()
        // Built directly: `projectId` is `let`, because an Issue cannot move
        // between Projects.
        let orphan = Issue.fixture(
            key: nil, projectId: Project.ID(), reporterId: f.user.id)

        #expect(throws: (any Error).self) {
            _ = try f.issues.create(orphan)
        }
    }
}
