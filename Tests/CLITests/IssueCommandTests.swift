import Core
import Foundation
import Server
import TestSupport
import Testing

@testable import CLI

typealias DomainIssue = Core.Issue

@Suite("issue list and show")
struct IssueCommandTests {

    private func sample(_ world: CLIWorld) -> [DomainIssue] {
        [
            DomainIssue.fixture(
                key: nil, projectId: world.project.id, title: "Sync queue stalls",
                status: .todo, priority: .high, reporterId: world.owner.id,
                assigneeId: world.owner.id),
            DomainIssue.fixture(
                key: nil, projectId: world.project.id, title: "Tighten the watermark",
                status: .inProgress, priority: .low, reporterId: world.owner.id),
            DomainIssue.fixture(
                key: nil, projectId: world.project.id, title: "Archive old projects",
                status: .done, priority: .none, reporterId: world.owner.id),
        ]
    }

    /// Builds a world, then creates issues through the repository so their keys
    /// come from the project's real counter.
    private func withIssues(
        _ body: @Sendable @escaping (CLIWorld, [DomainIssue]) async throws -> Void
    ) async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            var created: [DomainIssue] = []
            for issue in sample(world) {
                created.append(try repository.create(issue))
            }
            try await body(world, created)
        }
    }

    @Test("list renders a table of the project's issues")
    func listRendersATable() async throws {
        try await withIssues { world, issues in
            let result = await world.run(["list"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("KEY"))
            for issue in issues {
                #expect(result.standardOutput.contains(issue.title))
            }
        }
    }

    /// The whole point of the implied noun: `issues list` and `issues issue list`
    /// must be the same command.
    @Test("the implied noun and the long form agree")
    func impliedNounAndLongFormAgree() async throws {
        try await withIssues { world, _ in
            let short = await world.run(["list"])
            let long = await world.run(["issue", "list"])

            #expect(short.code == 0)
            #expect(short.standardOutput == long.standardOutput)
        }
    }

    /// `--quiet` exists to be piped into xargs, so it must emit keys and nothing
    /// else — no header, no padding, no "3 issues" summary.
    @Test("--quiet prints bare keys, one per line")
    func quietPrintsBareKeys() async throws {
        try await withIssues { world, issues in
            let result = await world.run(["list", "--quiet"])

            #expect(result.code == 0)
            let lines = result.standardOutput.split(separator: "\n").map(String.init)
            #expect(lines.count == issues.count)
            #expect(lines.allSatisfy { $0.hasPrefix("PROJ-") })
            #expect(!result.standardOutput.contains("KEY"))
        }
    }

    /// Ticket 11 requires the API payload rather than a CLI schema, so a field
    /// this build has never heard of has to survive to stdout.
    @Test("--json emits the API payload, including unknown fields")
    func jsonEmitsTheAPIPayload() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--json"])

            #expect(result.code == 0)
            let items = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
            let array = try #require(items as? [[String: Any]])
            #expect(array.count == 3)
            // Server field names, not renamed ones.
            #expect(array[0]["projectId"] != nil)
            #expect(array[0]["updatedAt"] != nil)
        }
    }

    @Test("--quiet wins over --json")
    func quietWinsOverJSON() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--quiet", "--json"])
            #expect(!result.standardOutput.contains("{"))
        }
    }

    @Test("filters narrow the result")
    func filtersNarrowTheResult() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--status", "todo", "--quiet"])

            #expect(result.code == 0)
            #expect(result.standardOutput.split(separator: "\n").count == 1)
        }
    }

    /// Values within one filter are OR-ed, which is the API's rule and needs to
    /// survive the flag design.
    @Test("comma-separated values are OR-ed")
    func commaSeparatedValuesAreOred() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--status", "todo,done", "--quiet"])
            #expect(result.standardOutput.split(separator: "\n").count == 2)
        }
    }

    @Test("repeating a flag matches comma separation")
    func repeatingAFlagMatchesCommaSeparation() async throws {
        try await withIssues { world, _ in
            let repeated = await world.run(["list", "--status", "todo", "--status", "done", "--quiet"])
            let commas = await world.run(["list", "--status", "todo,done", "--quiet"])
            #expect(repeated.standardOutput == commas.standardOutput)
        }
    }

    /// A mistyped status would otherwise filter to nothing and read as "you have
    /// no issues" rather than "you misspelled it".
    @Test("an unknown status is rejected rather than silently matching nothing")
    func unknownStatusIsRejected() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--status", "inprogress"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("inProgress"))
        }
    }

    @Test("an unknown sort is rejected")
    func unknownSortIsRejected() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--sort", "sideways"])
            #expect(result.code == 2)
        }
    }

    @Test("--assignee me resolves to the caller")
    func assigneeMeResolvesToTheCaller() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--assignee", "me", "--quiet"])

            #expect(result.code == 0)
            #expect(result.standardOutput.split(separator: "\n").count == 1)
        }
    }

    @Test("--assignee none finds the unassigned")
    func assigneeNoneFindsTheUnassigned() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--assignee", "none", "--quiet"])
            #expect(result.standardOutput.split(separator: "\n").count == 2)
        }
    }

    @Test("--assignee rejects something that is neither a token nor an id")
    func assigneeRejectsNonsense() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["list", "--assignee", "user"])
            #expect(result.code == 2)
        }
    }

    @Test("an empty result says so rather than printing an empty table")
    func emptyResultSaysSo() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["list"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("No issues matched"))
        }
    }

    /// Cursors are an API mechanism, not a user concept: --limit has to walk
    /// pages without ever mentioning one.
    @Test("--limit walks pages transparently")
    func limitWalksPages() async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            for index in 0..<12 {
                _ = try repository.create(
                    DomainIssue.fixture(
                        key: nil, projectId: world.project.id, title: "Issue \(index)",
                        reporterId: world.owner.id))
            }

            let result = await world.run(["list", "--limit", "5", "--quiet"])

            #expect(result.code == 0)
            #expect(result.standardOutput.split(separator: "\n").count == 5)
            #expect(!result.standardOutput.contains("cursor"))
        }
    }

    @Test("--all returns everything")
    func allReturnsEverything() async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            for index in 0..<12 {
                _ = try repository.create(
                    DomainIssue.fixture(
                        key: nil, projectId: world.project.id, title: "Issue \(index)",
                        reporterId: world.owner.id))
            }

            let result = await world.run(["list", "--all", "--quiet"])
            #expect(result.standardOutput.split(separator: "\n").count == 12)
        }
    }

    @Test("show renders one issue by key")
    func showRendersOneIssueByKey() async throws {
        try await withIssues { world, issues in
            let key = try #require(issues[0].key).wireValue
            let result = await world.run(["show", key])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains(issues[0].title))
            #expect(result.standardOutput.contains("Example User"))
        }
    }

    /// Key addressing exists so a human holding a key does not need a lookup
    /// round trip first; both forms must reach the same issue.
    @Test("show accepts an id as well as a key")
    func showAcceptsAnIdAsWellAsAKey() async throws {
        try await withIssues { world, issues in
            let byKey = await world.run(["show", try #require(issues[0].key).wireValue, "--json"])
            let byId = await world.run(["show", issues[0].id.rawValue.uuidString, "--json"])

            #expect(byKey.code == 0)
            #expect(byKey.standardOutput == byId.standardOutput)
        }
    }

    @Test("show rejects something that is neither a key nor an id")
    func showRejectsNonsense() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["show", "not-a-key"])
            #expect(result.code == 2)
            #expect(result.standardError.contains("PROJ-142"))
        }
    }

    @Test("a missing issue exits 3")
    func missingIssueExitsThree() async throws {
        try await withIssues { world, _ in
            let result = await world.run(["show", "PROJ-9999"])
            #expect(result.code == 3)
        }
    }

    /// The reason the server returns 410 rather than 404 reaches a user here, or
    /// it reaches nobody: "it was deleted" is a different branch from "no such
    /// thing", for a script and for a person.
    @Test("a deleted issue exits 6 and says it was deleted")
    func deletedIssueExitsSix() async throws {
        try await withIssues { world, issues in
            try IssueRepository(database: world.database).delete(issues[0].id, at: Date())

            let result = await world.run(["show", try #require(issues[0].key).wireValue])

            #expect(result.code == 6)
            #expect(result.standardError.lowercased().contains("deleted"))
            #expect(result.code != 3, "a deleted issue is not the same as a missing one")
        }
    }

    @Test("a command without a credential exits 4")
    func commandWithoutCredentialExitsFour() async throws {
        try await withCLI { world in
            let result = await world.run(["list"])
            #expect(result.code == 4)
            #expect(result.standardError.contains("auth login"))
        }
    }
}

@Suite("issue list options")
struct IssueListOptionTests {

    @Test("--project overrides the configured default")
    func projectOverridesTheDefault() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "In PROJ",
                    reporterId: world.owner.id))

            let matching = await world.run(["list", "--project", "PROJ", "--quiet"])
            let other = await world.run(["list", "--project", "WEB", "--quiet"])

            #expect(matching.standardOutput.contains("PROJ-"))
            #expect(other.standardOutput.isEmpty || other.code != 0)
        }
    }

    @Test("--project rejects a malformed key")
    func projectRejectsAMalformedKey() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["list", "--project", "not a key"])
            #expect(result.code == 2)
        }
    }

    @Test("--priority filters, and an unknown one is rejected")
    func priorityFilters() async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            _ = try repository.create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Urgent thing",
                    priority: .urgent, reporterId: world.owner.id))
            _ = try repository.create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Quiet thing",
                    priority: .low, reporterId: world.owner.id))

            let filtered = await world.run(["list", "--priority", "urgent", "--quiet"])
            #expect(filtered.standardOutput.split(separator: "\n").count == 1)

            let rejected = await world.run(["list", "--priority", "URGENT"])
            #expect(rejected.code == 2)
            #expect(rejected.standardError.contains("urgent"))
        }
    }

    @Test("--query matches text")
    func queryMatchesText() async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            _ = try repository.create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Watermark rewind",
                    reporterId: world.owner.id))
            _ = try repository.create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Unrelated",
                    reporterId: world.owner.id))

            let result = await world.run(["list", "--query", "Watermark", "--quiet"])
            #expect(result.standardOutput.split(separator: "\n").count == 1)
        }
    }

    @Test("--sort is accepted", arguments: ["updated", "created", "priority", "due"])
    func sortIsAccepted(_ sort: String) async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["list", "--sort", sort])
            #expect(result.code == 0)
        }
    }

    /// A leading '-' matches the wire format but argv reads it as a flag, so
    /// `--sort -updated` cannot work. `--reverse` is the form that always does.
    @Test("--reverse reverses, and so does an attached '-' prefix")
    func reverseReversesOrder() async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            for title in ["First", "Second", "Third"] {
                _ = try repository.create(
                    DomainIssue.fixture(
                        key: nil, projectId: world.project.id, title: title,
                        reporterId: world.owner.id))
            }

            let ascending = await world.run(["list", "--sort", "created", "--quiet"])
            let byFlag = await world.run(["list", "--sort", "created", "--reverse", "--quiet"])
            let byPrefix = await world.run(["list", "--sort=-created", "--quiet"])

            #expect(ascending.code == 0)
            #expect(byFlag.code == 0)
            #expect(byPrefix.standardOutput == byFlag.standardOutput)

            let forwards: [String] = ascending.standardOutput.split(separator: "\n").map(String.init)
            let backwards: [String] = byFlag.standardOutput.split(separator: "\n").map(String.init)
            #expect(backwards == forwards.reversed())
        }
    }

    /// Both forms together cancel, which is what anyone reading the command line
    /// would expect.
    @Test("a '-' prefix and --reverse cancel")
    func prefixAndReverseCancel() async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            for title in ["First", "Second"] {
                _ = try repository.create(
                    DomainIssue.fixture(
                        key: nil, projectId: world.project.id, title: title,
                        reporterId: world.owner.id))
            }

            let plain = await world.run(["list", "--sort", "created", "--quiet"])
            let both = await world.run(["list", "--sort=-created", "--reverse", "--quiet"])
            #expect(plain.standardOutput == both.standardOutput)
        }
    }

    /// A tombstone must not appear in a list; the server excludes it and the CLI
    /// must not undo that by asking for one.
    @Test("a deleted issue does not appear in a list")
    func deletedIssueDoesNotAppearInAList() async throws {
        try await withCLI { world in
            try world.authenticate()
            let repository = IssueRepository(database: world.database)
            let issue = try repository.create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Doomed",
                    reporterId: world.owner.id))
            try repository.delete(issue.id, at: Date())

            let result = await world.run(["list", "--quiet"])
            #expect(result.standardOutput.isEmpty)
        }
    }
}

@Suite("issue reads use expansion")
struct IssueExpansionUseTests {

    /// The payoff for implementing expand: the table shows names without the CLI
    /// fetching every user separately.
    @Test("the list table shows assignee names")
    func listTableShowsAssigneeNames() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Assigned",
                    reporterId: world.owner.id, assigneeId: world.owner.id))

            let result = await world.run(["list"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("Example User"))
        }
    }

    @Test("show displays reporter and assignee names")
    func showDisplaysNames() async throws {
        try await withCLI { world in
            try world.authenticate()
            let issue = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Assigned",
                    reporterId: world.owner.id, assigneeId: world.owner.id))

            let result = await world.run(["show", try #require(issue.key).wireValue])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("Reporter:  Example User"))
            #expect(result.standardOutput.contains("Assignee:  Example User"))
        }
    }

    @Test("an unassigned issue still reads clearly")
    func unassignedIssueStillReadsClearly() async throws {
        try await withCLI { world in
            try world.authenticate()
            let issue = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Nobody's",
                    reporterId: world.owner.id, assigneeId: nil))

            let result = await world.run(["show", try #require(issue.key).wireValue])
            #expect(result.standardOutput.contains("Assignee:  unassigned"))
        }
    }

    /// `--json` must stay the plain payload a script expects, so expansion is asked
    /// for only when rendering the human table.
    @Test("--json is not expanded")
    func jsonIsNotExpanded() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Assigned",
                    reporterId: world.owner.id, assigneeId: world.owner.id))

            let listed = await world.run(["list", "--json"])
            let items = try #require(
                try JSONSerialization.jsonObject(with: Data(listed.standardOutput.utf8))
                    as? [[String: Any]])
            #expect(items[0]["assignee"] == nil)
            #expect(items[0]["assigneeId"] != nil)

            let shown = await world.run(["show", "PROJ-1", "--json"])
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(shown.standardOutput.utf8))
                    as? [String: Any])
            #expect(object["assignee"] == nil)
        }
    }
}
