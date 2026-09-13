import Core
import Foundation
import Hummingbird
import HummingbirdTesting
import ServerTestSupport
import TestSupport
import Testing

@testable import MCP
@testable import Server

typealias DomainIssue = Core.Issue
typealias DomainUser = Core.User

/// The tools, against the real router. MCP is online-only with no queue, so it
/// sees ordinary REST responses.
@Suite("Tool runner")
struct ToolRunnerTests {

    private struct World: Sendable {
        let runner: ToolRunner
        let database: AppDatabase
        let owner: DomainUser
        let project: Project
    }

    /// `kind` defaults to agent, because that is what actually calls these.
    private func withWorld(
        kind: TokenKind = .agent,
        _ body: @Sendable @escaping (World) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let owner = DomainUser.fixture(email: "ada@example.com", displayName: "Ada", role: .admin)
        try UserRepository(database: database).save(owner)
        let project = Project.fixture(key: ProjectKey("PLAT")!, name: "Platform")
        try ProjectRepository(database: database).save(project)

        let session = try SessionRepository(database: database).create(
            for: owner.id, kind: kind, deviceId: nil, label: "mcp")

        // A generous limiter: these tests are about the tools, and the limit has its
        // own suite.
        let application = Application(
            router: IssuesRouter.build(database: database, rateLimiter: AgentRateLimiter()))
        try await application.test(.router) { client in
            let token = session.raw
            try await body(
                World(
                    runner: ToolRunner(
                        client: APIClient(
                            transport: RouterTransport(client: client), token: { token })),
                    database: database, owner: owner, project: project))
        }
    }

    private func issue(_ w: World, _ title: String, status: Status = .todo, priority: Priority = .none)
        throws -> DomainIssue
    {
        try IssueRepository(database: w.database).create(
            DomainIssue.fixture(
                key: nil, projectId: w.project.id, title: title, status: status,
                priority: priority, reporterId: w.owner.id))
    }

    // MARK: Reading

    @Test("list_issues returns a compact line per issue")
    func listIssuesReturnsACompactLine() async throws {
        try await withWorld { w in
            _ = try issue(w, "Sync queue stalls", status: .inProgress, priority: .urgent)

            let output = try await w.runner.call("list_issues", arguments: .object([:]))

            #expect(output.contains("PLAT-1"))
            #expect(output.contains("Sync queue stalls"))
            #expect(output.contains("inProgress"))
            #expect(output.contains("urgent"))
        }
    }

    /// The deviation ticket 12 takes knowingly: fifty issues with full Markdown can
    /// consume an agent's entire context in one call.
    @Test("list_issues omits descriptions")
    func listIssuesOmitsDescriptions() async throws {
        try await withWorld { w in
            _ = try IssueRepository(database: w.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: w.project.id, title: "Has detail",
                    description: "A very long description that would eat the context budget.",
                    reporterId: w.owner.id))

            let output = try await w.runner.call("list_issues", arguments: .object([:]))
            #expect(!output.contains("eat the context budget"))
        }
    }

    @Test("get_issue returns the full record including its description")
    func getIssueReturnsTheFullRecord() async throws {
        try await withWorld { w in
            _ = try IssueRepository(database: w.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: w.project.id, title: "Has detail",
                    description: "The whole story.", reporterId: w.owner.id))

            let output = try await w.runner.call(
                "get_issue", arguments: .object(["issue": .string("PLAT-1")]))

            #expect(output.contains("The whole story."))
            #expect(output.contains("Ada"))
        }
    }

    @Test("the default page size is small enough for a context budget")
    func defaultPageSizeIsSmall() async throws {
        try await withWorld { w in
            for index in 0..<40 { _ = try issue(w, "Issue \(index)") }

            let output = try await w.runner.call("list_issues", arguments: .object([:]))
            #expect(output.split(separator: "\n").count == ToolRunner.defaultLimit)
        }
    }

    @Test("a larger limit is capped")
    func largerLimitIsCapped() async throws {
        try await withWorld { w in
            for index in 0..<150 { _ = try issue(w, "Issue \(index)") }

            let output = try await w.runner.call(
                "list_issues", arguments: .object(["limit": .number(500)]))
            #expect(output.split(separator: "\n").count == ToolRunner.maximumLimit)
        }
    }

    @Test("filters narrow the result")
    func filtersNarrowTheResult() async throws {
        try await withWorld { w in
            _ = try issue(w, "Open one", status: .todo)
            _ = try issue(w, "Closed one", status: .done)

            let output = try await w.runner.call(
                "list_issues", arguments: .object(["status": .string("done")]))

            #expect(output.contains("Closed one"))
            #expect(!output.contains("Open one"))
        }
    }

    /// A mistyped status would otherwise filter to nothing and read as "there are
    /// none" rather than "you misspelled it".
    @Test("an unknown status is refused with the known ones")
    func unknownStatusIsRefused() async throws {
        try await withWorld { w in
            await #expect(throws: ToolFailure.self) {
                try await w.runner.call(
                    "list_issues", arguments: .object(["status": .string("inprogress")]))
            }
        }
    }

    @Test("an empty result says so rather than returning nothing")
    func emptyResultSaysSo() async throws {
        try await withWorld { w in
            let output = try await w.runner.call("list_issues", arguments: .object([:]))
            #expect(output.contains("No issues"))
        }
    }

    // MARK: Writing

    @Test("create_issue creates one and reports its key")
    func createIssueCreatesOne() async throws {
        try await withWorld { w in
            let output = try await w.runner.call(
                "create_issue",
                arguments: .object([
                    "project": .string("PLAT"), "title": .string("Filed by an agent"),
                ]))

            #expect(output.contains("PLAT-1"))
            let stored = try IssueRepository(database: w.database).find(key: IssueKey("PLAT-1")!)
            #expect(stored?.title == "Filed by an agent")
        }
    }

    /// The whole point of `via`: answering "which of these did the bot file?".
    @Test("an agent's issue is attributed to an agent")
    func agentsIssueIsAttributedToAnAgent() async throws {
        try await withWorld { w in
            _ = try await w.runner.call(
                "create_issue",
                arguments: .object([
                    "project": .string("PLAT"), "title": .string("Filed by an agent"),
                ]))

            let stored = try IssueRepository(database: w.database).find(key: IssueKey("PLAT-1")!)
            #expect(stored?.via == .agent)
        }
    }

    @Test("a missing title is refused before any request")
    func missingTitleIsRefused() async throws {
        try await withWorld { w in
            await #expect(throws: ToolFailure.self) {
                try await w.runner.call(
                    "create_issue", arguments: .object(["project": .string("PLAT")]))
            }
        }
    }

    @Test("an unknown project key lists the known ones")
    func unknownProjectKeyListsKnownOnes() async throws {
        try await withWorld { w in
            do {
                _ = try await w.runner.call(
                    "create_issue",
                    arguments: .object(["project": .string("NOPE"), "title": .string("x")]))
                Issue.record("expected a failure")
            } catch let failure as ToolFailure {
                #expect(failure.description.contains("PLAT"))
            }
        }
    }

    /// Merge Patch: only the named fields move.
    @Test("update_issue changes only what it names")
    func updateIssueChangesOnlyWhatItNames() async throws {
        try await withWorld { w in
            let existing = try issue(w, "Original", priority: .high)

            _ = try await w.runner.call(
                "update_issue",
                arguments: .object(["issue": .string("PLAT-1"), "title": .string("Renamed")]))

            let stored = try IssueRepository(database: w.database).find(existing.id)
            #expect(stored?.title == "Renamed")
            #expect(stored?.priority == .high)
        }
    }

    /// An agent's way to make something go away, since there is no delete.
    @Test("update_issue can cancel an issue")
    func updateIssueCanCancel() async throws {
        try await withWorld { w in
            let existing = try issue(w, "Abandon me")

            _ = try await w.runner.call(
                "update_issue",
                arguments: .object([
                    "issue": .string("PLAT-1"), "status": .string("cancelled"),
                ]))

            #expect(try IssueRepository(database: w.database).find(existing.id)?.status == .cancelled)
        }
    }

    @Test("an update with nothing to change says so")
    func updateWithNothingToChangeSaysSo() async throws {
        try await withWorld { w in
            _ = try issue(w, "Unchanged")

            await #expect(throws: ToolFailure.self) {
                try await w.runner.call(
                    "update_issue", arguments: .object(["issue": .string("PLAT-1")]))
            }
        }
    }

    @Test("add_comment posts one, attributed to an agent")
    func addCommentPostsOne() async throws {
        try await withWorld { w in
            let existing = try issue(w, "Needs discussion")

            _ = try await w.runner.call(
                "add_comment",
                arguments: .object([
                    "issue": .string("PLAT-1"), "body": .string("Looks right to me."),
                ]))

            let thread = try CommentRepository(database: w.database).thread(for: existing.id)
            #expect(thread.first?.body == "Looks right to me.")
            #expect(thread.first?.via == .agent)
        }
    }

    @Test("list_comments reads the thread")
    func listCommentsReadsTheThread() async throws {
        try await withWorld { w in
            _ = try issue(w, "Needs discussion")
            _ = try await w.runner.call(
                "add_comment",
                arguments: .object(["issue": .string("PLAT-1"), "body": .string("First")]))

            let output = try await w.runner.call(
                "list_comments", arguments: .object(["issue": .string("PLAT-1")]))
            #expect(output.contains("First"))
        }
    }

    // MARK: Orientation

    @Test("list_projects gives the keys an agent needs")
    func listProjectsGivesTheKeys() async throws {
        try await withWorld { w in
            let output = try await w.runner.call("list_projects", arguments: .object([:]))
            #expect(output.contains("PLAT"))
            #expect(output.contains("Platform"))
        }
    }

    /// It exists only so a name can be resolved to the id assignment needs.
    @Test("list_users gives ids alongside names")
    func listUsersGivesIdsAlongsideNames() async throws {
        try await withWorld { w in
            let output = try await w.runner.call("list_users", arguments: .object([:]))

            #expect(output.contains(w.owner.id.rawValue.uuidString))
            #expect(output.contains("Ada"))
        }
    }

    @Test("whoami identifies the token and states its limits")
    func whoamiIdentifiesTheToken() async throws {
        try await withWorld { w in
            let output = try await w.runner.call("whoami", arguments: .object([:]))

            #expect(output.contains("ada@example.com"))
            #expect(output.contains("cannot"))
        }
    }
}

@Suite("Tool runner filters")
struct ToolRunnerFilterTests {

    private func withWorld(
        _ body:
            @Sendable @escaping (ToolRunner, AppDatabase, DomainUser, Project) async throws ->
            Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let owner = DomainUser.fixture(email: "ada@example.com", displayName: "Ada", role: .admin)
        try UserRepository(database: database).save(owner)
        let projects = ProjectRepository(database: database)
        let platform = Project.fixture(key: ProjectKey("PLAT")!, name: "Platform")
        let web = Project.fixture(id: Project.ID(), key: ProjectKey("WEB")!, name: "Website")
        try projects.save(platform)
        try projects.save(web)

        let repository = IssueRepository(database: database)
        _ = try repository.create(
            DomainIssue.fixture(
                key: nil, projectId: platform.id, title: "In platform",
                reporterId: owner.id, assigneeId: owner.id))
        _ = try repository.create(
            DomainIssue.fixture(
                key: nil, projectId: web.id, title: "In website", reporterId: owner.id))

        let session = try SessionRepository(database: database).create(
            for: owner.id, kind: .agent, deviceId: nil, label: "mcp")
        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            let token = session.raw
            try await body(
                ToolRunner(
                    client: APIClient(
                        transport: RouterTransport(client: client), token: { token })),
                database, owner, platform)
        }
    }

    @Test("the project filter narrows to one project")
    func projectFilterNarrows() async throws {
        try await withWorld { runner, _, _, _ in
            let output = try await runner.call(
                "list_issues", arguments: .object(["project": .string("PLAT")]))

            #expect(output.contains("In platform"))
            #expect(!output.contains("In website"))
        }
    }

    @Test("a malformed project key is refused with what a key looks like")
    func malformedProjectKeyIsRefused() async throws {
        try await withWorld { runner, _, _, _ in
            do {
                _ = try await runner.call(
                    "list_issues", arguments: .object(["project": .string("lower case")]))
                Issue.record("expected a failure")
            } catch let failure as ToolFailure {
                #expect(failure.description.contains("A-Z"))
            }
        }
    }

    /// The tokens exist so an agent does not have to resolve its own id first.
    @Test("assignee accepts me and none")
    func assigneeAcceptsMeAndNone() async throws {
        try await withWorld { runner, _, _, _ in
            let mine = try await runner.call(
                "list_issues", arguments: .object(["assignee": .string("me")]))
            #expect(mine.contains("In platform"))
            #expect(!mine.contains("In website"))

            let unassigned = try await runner.call(
                "list_issues", arguments: .object(["assignee": .string("none")]))
            #expect(unassigned.contains("In website"))
        }
    }

    @Test("assignee accepts a user id")
    func assigneeAcceptsAUserId() async throws {
        try await withWorld { runner, _, owner, _ in
            let output = try await runner.call(
                "list_issues",
                arguments: .object(["assignee": .string(owner.id.rawValue.uuidString)]))
            #expect(output.contains("In platform"))
        }
    }

    @Test("an assignee that is neither a token nor an id is refused")
    func assigneeThatIsNeitherIsRefused() async throws {
        try await withWorld { runner, _, _, _ in
            await #expect(throws: ToolFailure.self) {
                try await runner.call(
                    "list_issues", arguments: .object(["assignee": .string("Ada")]))
            }
        }
    }

    @Test("the priority filter narrows the result")
    func priorityFilterNarrows() async throws {
        try await withWorld { runner, database, owner, project in
            _ = try IssueRepository(database: database).create(
                DomainIssue.fixture(
                    key: nil, projectId: project.id, title: "Urgent one", priority: .urgent,
                    reporterId: owner.id))

            let output = try await runner.call(
                "list_issues", arguments: .object(["priority": .string("urgent")]))

            #expect(output.contains("Urgent one"))
            #expect(!output.contains("In platform"))
        }
    }

    @Test("an unknown priority is refused")
    func unknownPriorityIsRefused() async throws {
        try await withWorld { runner, _, _, _ in
            await #expect(throws: ToolFailure.self) {
                try await runner.call(
                    "list_issues", arguments: .object(["priority": .string("URGENT")]))
            }
        }
    }

    @Test("the text query matches")
    func textQueryMatches() async throws {
        try await withWorld { runner, _, _, _ in
            let output = try await runner.call(
                "list_issues", arguments: .object(["query": .string("website")]))
            #expect(output.contains("In website"))
        }
    }

    @Test("list_labels reads a project's labels")
    func listLabelsReadsAProjectsLabels() async throws {
        try await withWorld { runner, database, _, project in
            _ = try LabelRepository(database: database).save(
                Label.fixture(projectId: project.id, name: "bug"))

            let output = try await runner.call(
                "list_labels", arguments: .object(["project": .string("PLAT")]))
            #expect(output.contains("bug"))
        }
    }

    @Test("a project with no labels says so")
    func projectWithNoLabelsSaysSo() async throws {
        try await withWorld { runner, _, _, _ in
            let output = try await runner.call(
                "list_labels", arguments: .object(["project": .string("PLAT")]))
            #expect(output.contains("No labels"))
        }
    }

    @Test("an issue reference that is neither a key nor an id is refused")
    func referenceThatIsNeitherIsRefused() async throws {
        try await withWorld { runner, _, _, _ in
            do {
                _ = try await runner.call(
                    "get_issue", arguments: .object(["issue": .string("not-a-key")]))
                Issue.record("expected a failure")
            } catch let failure as ToolFailure {
                #expect(failure.description.contains("PLAT-142"))
            }
        }
    }
}
