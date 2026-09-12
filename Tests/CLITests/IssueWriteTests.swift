import Core
import Foundation
import Server
import Synchronization
import TestSupport
import Testing

@testable import CLI

typealias DomainUser = Core.User

@Suite("issue create")
struct IssueCreateTests {

    @Test("create makes an issue and reports its key")
    func createMakesAnIssue() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "--title", "Watermark rewinds after restore"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("PROJ-"))

            let listed = await world.run(["list", "--quiet"])
            #expect(listed.standardOutput.split(separator: "\n").count == 1)
        }
    }

    /// The id is generated client-side so a retry after a lost response cannot
    /// produce two issues. Two separate creates must still be two issues.
    @Test("two creates make two issues")
    func twoCreatesMakeTwoIssues() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["create", "-t", "One"])
            _ = await world.run(["create", "-t", "Two"])

            let listed = await world.run(["list", "--quiet"])
            #expect(listed.standardOutput.split(separator: "\n").count == 2)
        }
    }

    @Test("a title is required")
    func titleIsRequired() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--title"))
        }
    }

    @Test("a blank title is refused")
    func blankTitleIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "   "])
            #expect(result.code == 2)
        }
    }

    @Test("fields set at creation are stored")
    func fieldsSetAtCreationAreStored() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run([
                "create", "-t", "Full", "--status", "inProgress", "--priority", "high",
                "--due", "2026-12-25", "--assignee", "me", "--json",
            ])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.status == .inProgress)
            #expect(issue.priority == .high)
            #expect(issue.dueDate?.wireValue == "2026-12-25")
            #expect(issue.assigneeId == world.owner.id)
        }
    }

    /// A description is optional, so a scripted create with no terminal simply
    /// gets none. Failing here would break every CI create.
    @Test("no description and no terminal is not an error")
    func noDescriptionAndNoTerminalIsNotAnError() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "Terse", "--json"])

            #expect(result.code == 0)
            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.description.isEmpty)
        }
    }

    @Test("a description is read from stdin with '-'")
    func descriptionIsReadFromStdin() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["create", "-t", "Piped", "-d", "-", "--json"],
                standardInput: "From a pipe.\n")

            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.description == "From a pipe.")
        }
    }

    @Test("the editor supplies a description at a terminal")
    func editorSuppliesADescription() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["create", "-t", "Edited", "--json"],
                isInputTerminal: true,
                editor: { _ in "Written in the editor." })

            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.description == "Written in the editor.")
        }
    }

    /// Abandoning the editor must not invent an empty description and carry on
    /// silently — but for an optional field, carrying on with none is correct.
    @Test("abandoning the editor still creates, with no description")
    func abandoningTheEditorStillCreates() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["create", "-t", "Abandoned", "--json"],
                isInputTerminal: true, editor: { _ in nil })

            #expect(result.code == 0)
            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.description.isEmpty)
        }
    }

    @Test("--no-edit suppresses the editor")
    func noEditSuppressesTheEditor() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["create", "-t", "Quiet", "--no-edit", "--json"],
                isInputTerminal: true,
                editor: { _ in "should never be reached" })

            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.description.isEmpty)
        }
    }

    @Test("labels are applied by name")
    func labelsAreAppliedByName() async throws {
        try await withCLI { world in
            try world.authenticate()
            let label = Label.fixture(projectId: world.project.id, name: "bug")
            _ = try LabelRepository(database: world.database).save(label)

            let result = await world.run(["create", "-t", "Tagged", "--label", "bug"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))
        }
    }

    /// A tracker where every typo silently becomes a new label fills up with
    /// near-duplicates nobody ever cleans out.
    @Test("an unknown label is refused, naming the command that creates one")
    func unknownLabelIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "Tagged", "--label", "buhg"])

            #expect(result.code != 0)
            #expect(result.standardError.contains("issues label create"))
        }
    }

    @Test("label names are matched case-insensitively")
    func labelNamesAreCaseInsensitive() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = try LabelRepository(database: world.database).save(
                Label.fixture(projectId: world.project.id, name: "Bug"))

            let result = await world.run(["create", "-t", "Tagged", "--label", "bug"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))
        }
    }

    /// Without a project there is nothing to create in, and the message has to
    /// name every way of supplying one.
    @Test("no project names all the ways to set one")
    func noProjectNamesAllTheWays() async throws {
        try await withCLI(configuresProject: false) { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "Homeless", "--no-edit"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--project"))
            #expect(result.standardError.contains("config set project"))
            #expect(result.standardError.contains(".issues.toml"))
        }
    }

    @Test("an unknown project lists the known ones")
    func unknownProjectListsKnownOnes() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "Lost", "--project", "NOPE"])

            #expect(result.code != 0)
            #expect(result.standardError.contains("PROJ"))
        }
    }

    @Test("a malformed due date is rejected")
    func malformedDueDateIsRejected() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "x", "--due", "25-12-2026"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("YYYY-MM-DD"))
        }
    }

    /// A calendar date is not an instant; accepting one would reintroduce the
    /// timezone drift CivilDate exists to prevent.
    @Test("an RFC 3339 instant is not a due date")
    func rfc3339InstantIsNotADueDate() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "x", "--due", "2026-12-25T00:00:00Z"])
            #expect(result.code == 2)
        }
    }
}

@Suite("issue edit")
struct IssueEditTests {

    private func withIssue(
        _ body: @Sendable @escaping (CLIWorld, DomainIssue) async throws -> Void
    ) async throws {
        try await withCLI { world in
            try world.authenticate()
            let issue = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Original title",
                    description: "Original description.", status: .todo, priority: .none,
                    reporterId: world.owner.id, assigneeId: world.owner.id,
                    dueDate: CivilDate(wireValue: "2026-01-01")))
            try await body(world, issue)
        }
    }

    private func reread(_ world: CLIWorld, _ issue: DomainIssue) throws -> DomainIssue {
        try #require(try IssueRepository(database: world.database).find(issue.id))
    }

    /// Merge Patch's whole point: only the named field moves.
    @Test("editing one field leaves the others alone")
    func editingOneFieldLeavesOthersAlone() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["edit", key, "--title", "New title"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let updated = try reread(world, issue)
            #expect(updated.title == "New title")
            #expect(updated.description == "Original description.")
            #expect(updated.priority == .none)
            #expect(updated.assigneeId == world.owner.id)
            #expect(updated.dueDate?.wireValue == "2026-01-01")
        }
    }

    /// `--unset` is the CLI's expression of Merge Patch's third state: an explicit
    /// null, which is different from omitting the key.
    @Test("--unset clears a field", arguments: ["assignee", "due"])
    func unsetClearsAField(_ field: String) async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["edit", key, "--unset", field])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let updated = try reread(world, issue)
            switch field {
            case "assignee": #expect(updated.assigneeId == nil)
            default: #expect(updated.dueDate == nil)
            }
        }
    }

    @Test("--unset leaves the other fields alone")
    func unsetLeavesOtherFieldsAlone() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            _ = await world.run(["edit", key, "--unset", "assignee"])

            let updated = try reread(world, issue)
            #expect(updated.assigneeId == nil)
            #expect(updated.dueDate?.wireValue == "2026-01-01")
            #expect(updated.title == "Original title")
        }
    }

    @Test("--unset is repeatable")
    func unsetIsRepeatable() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            _ = await world.run(["edit", key, "--unset", "assignee", "--unset", "due"])

            let updated = try reread(world, issue)
            #expect(updated.assigneeId == nil)
            #expect(updated.dueDate == nil)
        }
    }

    /// `status` is non-nullable in the API, so clearing it cannot be expressed at
    /// all. Rejecting it by name beats sending a request the server must refuse.
    @Test("--unset refuses a field that cannot be cleared", arguments: ["status", "title", "priority"])
    func unsetRefusesNonNullableFields(_ field: String) async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["edit", key, "--unset", field])

            #expect(result.code == 2)
            #expect(result.standardError.contains("assignee"))
        }
    }

    /// Silently succeeding would look exactly like the edit was applied.
    @Test("an edit that changes nothing is an error naming the flags")
    func editThatChangesNothingIsAnError() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["edit", key, "--no-edit"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--status"))
        }
    }

    @Test("the editor edits the description, seeded with the current text")
    func editorEditsTheDescription() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let seen = Mutex<String>("")
            let result = await world.run(
                ["edit", key],
                isInputTerminal: true,
                editor: { template in
                    seen.withLock { $0 = template }
                    return "Rewritten."
                })

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(seen.withLock { $0 }.contains("Original description."))
            #expect(try reread(world, issue).description == "Rewritten.")
        }
    }

    /// Otherwise `issues edit PROJ-1 --status done` would stop for a text editor
    /// nobody asked for.
    @Test("naming another field does not open the editor")
    func namingAnotherFieldDoesNotOpenTheEditor() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(
                ["edit", key, "--status", "done"],
                isInputTerminal: true,
                editor: { _ in "should never be reached" })

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let updated = try reread(world, issue)
            #expect(updated.status == .done)
            #expect(updated.description == "Original description.")
        }
    }

    @Test("abandoning the editor changes nothing")
    func abandoningTheEditorChangesNothing() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(
                ["edit", key], isInputTerminal: true, editor: { _ in nil })

            #expect(result.code == 2)
            #expect(try reread(world, issue).description == "Original description.")
        }
    }

    /// Saving the buffer untouched must not register as a change, or every opened
    /// editor would bump `updatedAt` and win a last-write-wins race it should not
    /// have entered.
    @Test("saving the description unchanged is not a write")
    func savingUnchangedIsNotAWrite() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let before = try reread(world, issue).updatedAt

            let result = await world.run(
                ["edit", key],
                isInputTerminal: true,
                editor: { Editor.content(of: $0) })

            #expect(result.code == 2, "an unchanged buffer counted as an edit")
            #expect(try reread(world, issue).updatedAt == before)
        }
    }

    @Test("an assignee can be named by email")
    func assigneeCanBeNamedByEmail() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            _ = await world.run(["edit", key, "--unset", "assignee"])

            let result = await world.run(["edit", key, "--assignee", "saqib@example.com"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(try reread(world, issue).assigneeId == world.owner.id)
        }
    }

    @Test("an unknown assignee is refused with the forms that work")
    func unknownAssigneeIsRefused() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["edit", key, "--assignee", "nobody@example.com"])

            #expect(result.code != 0)
            #expect(result.standardError.contains("email address"))
        }
    }

    @Test("labels are added and removed by name")
    func labelsAreAddedAndRemovedByName() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let labels = LabelRepository(database: world.database)
            _ = try labels.save(Label.fixture(projectId: world.project.id, name: "bug"))

            let added = await world.run(["edit", key, "--label", "bug"])
            #expect(added.code == 0, Comment(rawValue: added.standardError))

            let removed = await world.run(["edit", key, "--remove-label", "bug"])
            #expect(removed.code == 0, Comment(rawValue: removed.standardError))
        }
    }

    /// A label change needs no --project: the issue already names its own, and
    /// asking again would let somebody apply a label from the wrong project.
    @Test("a label change needs no project flag")
    func labelChangeNeedsNoProjectFlag() async throws {
        try await withCLI(configuresProject: false) { world in
            try world.authenticate()
            let issue = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Tagged",
                    reporterId: world.owner.id))
            _ = try LabelRepository(database: world.database).save(
                Label.fixture(projectId: world.project.id, name: "bug"))

            let key = try #require(issue.key).wireValue
            let result = await world.run(["edit", key, "--label", "bug"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))
        }
    }

    @Test("editing a deleted issue exits 6")
    func editingADeletedIssueExitsSix() async throws {
        try await withIssue { world, issue in
            try IssueRepository(database: world.database).delete(issue.id, at: Date())
            let key = try #require(issue.key).wireValue

            let result = await world.run(["edit", key, "--title", "Too late"])
            #expect(result.code == 6)
        }
    }

    @Test("editing a missing issue exits 3")
    func editingAMissingIssueExitsThree() async throws {
        try await withIssue { world, _ in
            let result = await world.run(["edit", "PROJ-9999", "--title", "Nowhere"])
            #expect(result.code == 3)
        }
    }
}

@Suite("issue status shortcuts")
struct IssueShortcutTests {

    private func withIssue(
        _ body: @Sendable @escaping (CLIWorld, DomainIssue) async throws -> Void
    ) async throws {
        try await withCLI { world in
            try world.authenticate()
            let issue = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Shortcut target",
                    status: .todo, reporterId: world.owner.id))
            try await body(world, issue)
        }
    }

    @Test(
        "the shortcuts set their status",
        arguments: [
            ("close", Status.done),
            ("start", Status.inProgress),
            ("cancel", Status.cancelled),
        ])
    func shortcutsSetTheirStatus(verb: String, expected: Status) async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run([verb, key])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let updated = try #require(try IssueRepository(database: world.database).find(issue.id))
            #expect(updated.status == expected)
        }
    }

    /// Reopening has to exist, or closing something by mistake needs the long form
    /// to undo.
    @Test("reopen moves an issue back to todo")
    func reopenMovesBackToTodo() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            _ = await world.run(["close", key])
            let result = await world.run(["reopen", key])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let updated = try #require(try IssueRepository(database: world.database).find(issue.id))
            #expect(updated.status == .todo)
        }
    }

    /// Sugar has to mean exactly what the long form means, or it becomes a second
    /// code path with its own bugs.
    @Test("close is the same as edit --status done")
    func closeIsTheSameAsEditStatusDone() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let viaSugar = await world.run(["close", key, "--json"])
            _ = await world.run(["reopen", key])
            let viaEdit = await world.run(["edit", key, "--status", "done", "--json"])

            let a = try JSONCoders.decoder.decode(DomainIssue.self, from: Data(viaSugar.standardOutput.utf8))
            let b = try JSONCoders.decoder.decode(DomainIssue.self, from: Data(viaEdit.standardOutput.utf8))
            #expect(a.status == b.status)
            #expect(a.id == b.id)
        }
    }

    @Test("assign sets an assignee, and --to none clears it")
    func assignSetsAndClears() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let repository = IssueRepository(database: world.database)

            let assigned = await world.run(["assign", key, "--to", "me"])
            #expect(assigned.code == 0, Comment(rawValue: assigned.standardError))
            #expect(try repository.find(issue.id)?.assigneeId == world.owner.id)

            let cleared = await world.run(["assign", key, "--to", "none"])
            #expect(cleared.code == 0, Comment(rawValue: cleared.standardError))
            #expect(try repository.find(issue.id)?.assigneeId == nil)
        }
    }
}

@Suite("issue comment and delete")
struct IssueCommentAndDeleteTests {

    private func withIssue(
        _ body: @Sendable @escaping (CLIWorld, DomainIssue) async throws -> Void
    ) async throws {
        try await withCLI { world in
            try world.authenticate()
            let issue = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Needs discussion",
                    reporterId: world.owner.id))
            try await body(world, issue)
        }
    }

    @Test("comment posts a body given inline")
    func commentPostsABodyGivenInline() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["comment", key, "-m", "Looks right to me."])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let stored = try CommentRepository(database: world.database).thread(for: issue.id)
            #expect(stored.count == 1)
            #expect(stored.first?.body == "Looks right to me.")
        }
    }

    @Test("comment reads a body from stdin")
    func commentReadsABodyFromStdin() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(
                ["comment", key, "-m", "-"], standardInput: "Piped comment.\n")

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let stored = try CommentRepository(database: world.database).thread(for: issue.id)
            #expect(stored.first?.body == "Piped comment.")
        }
    }

    /// A body is required, so this is where ticket 11's "fail naming the missing
    /// flag" applies — an empty comment is not a comment.
    @Test("a comment with no body and no terminal names the flag")
    func commentWithNoBodyNamesTheFlag() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["comment", key])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--message"))
        }
    }

    @Test("an empty stdin body is refused rather than posted")
    func emptyStdinBodyIsRefused() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["comment", key, "-m", "-"], standardInput: "\n\n")

            #expect(result.code == 2)
            #expect(try CommentRepository(database: world.database).thread(for: issue.id).isEmpty)
        }
    }

    @Test("abandoning the editor posts nothing")
    func abandoningTheEditorPostsNothing() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(
                ["comment", key], isInputTerminal: true, editor: { _ in nil })

            #expect(result.code != 0)
            #expect(try CommentRepository(database: world.database).thread(for: issue.id).isEmpty)
        }
    }

    /// A key alone gives you nothing to notice you have the wrong issue, and the
    /// tombstone is not undoable from the CLI.
    @Test("delete confirms with the issue's title")
    func deleteConfirmsWithTheTitle() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(
                ["delete", key], isInputTerminal: true, input: ["y"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            // The title is in the prompt, which is on stderr so stdout stays clean.
            #expect(result.standardError.contains("Needs discussion"))
            #expect(try IssueRepository(database: world.database).find(issue.id)?.isDeleted == true)
        }
    }

    @Test("declining the confirmation deletes nothing", arguments: ["n", "", "no thanks", "Y ES"])
    func decliningDeletesNothing(_ answer: String) async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(
                ["delete", key], isInputTerminal: true, input: [answer])

            #expect(result.code != 0)
            #expect(try IssueRepository(database: world.database).find(issue.id)?.isDeleted == false)
        }
    }

    /// Off a terminal there is nobody to ask, so a destructive command must refuse
    /// rather than block on a prompt that will never be answered.
    @Test("delete off a terminal requires --yes")
    func deleteOffATerminalRequiresYes() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["delete", key])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--yes"))
            #expect(try IssueRepository(database: world.database).find(issue.id)?.isDeleted == false)
        }
    }

    @Test("--yes deletes without asking")
    func yesDeletesWithoutAsking() async throws {
        try await withIssue { world, issue in
            let key = try #require(issue.key).wireValue
            let result = await world.run(["delete", key, "--yes"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(try IssueRepository(database: world.database).find(issue.id)?.isDeleted == true)
        }
    }

    @Test("deleting something already deleted exits 6")
    func deletingSomethingAlreadyDeletedExitsSix() async throws {
        try await withIssue { world, issue in
            try IssueRepository(database: world.database).delete(issue.id, at: Date())
            let key = try #require(issue.key).wireValue

            let result = await world.run(["delete", key, "--yes"])
            #expect(result.code == 6)
        }
    }
}

@Suite("issue write option validation")
struct IssueWriteValidationTests {

    /// `list` and the write commands parse these separately, so covering one does
    /// not cover the other.
    @Test(
        "a bad status or priority is rejected on the write path",
        arguments: [
            ["create", "-t", "x", "--status", "inprogress"],
            ["create", "-t", "x", "--priority", "URGENT"],
            ["edit", "PROJ-1", "--status", "finished"],
            ["edit", "PROJ-1", "--priority", "highest"],
        ])
    func badStatusOrPriorityIsRejectedOnTheWritePath(_ arguments: [String]) async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(arguments)

            #expect(result.code == 2)
            #expect(!result.standardError.isEmpty)
        }
    }

    @Test("a malformed --project is rejected before any request")
    func malformedProjectIsRejected() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "x", "--project", "lower case"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("project key"))
        }
    }

    /// Two people with the same display name must not resolve to whichever the
    /// server happened to return first.
    @Test("an ambiguous assignee is refused rather than guessed")
    func ambiguousAssigneeIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            let users = UserRepository(database: world.database)
            try users.save(
                DomainUser.fixture(email: "sam.a@example.com", displayName: "Sam"))
            try users.save(
                DomainUser.fixture(email: "sam.b@example.com", displayName: "Sam"))

            let result = await world.run(["create", "-t", "x", "--assignee", "Sam"])

            #expect(result.code != 0)
            #expect(result.standardError.contains("matches 2 users"))
        }
    }

    @Test("an assignee can still be named by display name when unambiguous")
    func unambiguousDisplayNameWorks() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["create", "-t", "x", "--assignee", "Saqib", "--json"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.assigneeId == world.owner.id)
        }
    }

    @Test("an assignee can be named by user id")
    func assigneeCanBeNamedById() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run([
                "create", "-t", "x", "--assignee", world.owner.id.rawValue.uuidString, "--json",
            ])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.assigneeId == world.owner.id)
        }
    }

    /// `issues create -q` prints a bare key, which is what makes `issues create -q
    /// | xargs issues show` work.
    @Test(
        "--quiet on a write prints just the key",
        arguments: [
            ["create", "-t", "Quiet create"]
        ])
    func quietOnAWritePrintsJustTheKey(_ arguments: [String]) async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(arguments + ["--quiet"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let printed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(printed.hasPrefix("PROJ-"))
            #expect(!printed.contains(" "))
        }
    }

    @Test("--quiet on an edit prints just the key")
    func quietOnAnEditPrintsJustTheKey() async throws {
        try await withCLI { world in
            try world.authenticate()
            let issue = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Target",
                    reporterId: world.owner.id))
            let key = try #require(issue.key).wireValue

            let result = await world.run(["close", key, "--quiet"])
            #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == key)
        }
    }

    /// An optional field with an empty pipe is simply absent, not a failure.
    @Test("an empty piped description is accepted as none")
    func emptyPipedDescriptionIsAcceptedAsNone() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["create", "-t", "Empty pipe", "-d", "-", "--json"], standardInput: "   \n")

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let issue = try JSONCoders.decoder.decode(
                DomainIssue.self, from: Data(result.standardOutput.utf8))
            #expect(issue.description.isEmpty)
        }
    }
}
