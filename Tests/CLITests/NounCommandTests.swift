import Core
import Foundation
import Server
import Synchronization
import TestSupport
import Testing

@testable import CLI

@Suite("project")
struct ProjectCommandTests {

    @Test("list shows the project")
    func listShowsTheProject() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "list"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("PROJ"))
            #expect(result.standardOutput.contains("Platform"))
        }
    }

    @Test("create makes a project")
    func createMakesAProject() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "create", "WEB", "--name", "Website"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let listed = await world.run(["project", "list", "--quiet"])
            #expect(listed.standardOutput.contains("WEB"))
        }
    }

    @Test("a malformed key is rejected before any request")
    func malformedKeyIsRejected() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "create", "lower", "--name", "x"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("A-Z"))
        }
    }

    /// Admin-only commands are listed for everyone and rejected at call, so help
    /// never depends on who you are.
    @Test("a member is refused, but the command still exists")
    func memberIsRefusedButCommandExists() async throws {
        try await withCLI { world in
            try world.authenticateAsMember()
            let result = await world.run(["project", "create", "WEB", "--name", "Website"])

            #expect(result.code == 4)
            #expect(result.standardError.contains("admin"))

            let help = await world.run(["project", "--help"])
            #expect(help.standardOutput.contains("create"))
        }
    }

    @Test("show accepts a key and an id")
    func showAcceptsAKeyAndAnId() async throws {
        try await withCLI { world in
            try world.authenticate()
            let byKey = await world.run(["project", "show", "PROJ", "--json"])
            let byId = await world.run(
                ["project", "show", world.project.id.rawValue.uuidString, "--json"])

            #expect(byKey.code == 0, Comment(rawValue: byKey.standardError))
            #expect(byKey.standardOutput == byId.standardOutput)
        }
    }

    @Test("an unknown key lists the known ones")
    func unknownKeyListsKnownOnes() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "show", "NOPE"])

            #expect(result.code != 0)
            #expect(result.standardError.contains("PROJ"))
        }
    }

    @Test("edit changes the name")
    func editChangesTheName() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "edit", "PROJ", "--name", "Renamed"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let shown = await world.run(["project", "show", "PROJ"])
            #expect(shown.standardOutput.contains("Renamed"))
        }
    }

    @Test("an edit that changes nothing is an error")
    func editThatChangesNothingIsAnError() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "edit", "PROJ"])
            #expect(result.code == 2)
        }
    }

    @Test("archive hides a project from the default list")
    func archiveHidesFromDefaultList() async throws {
        try await withCLI { world in
            try world.authenticate()
            let archived = await world.run(["project", "archive", "PROJ", "--yes"])
            #expect(archived.code == 0, Comment(rawValue: archived.standardError))

            let listed = await world.run(["project", "list"])
            #expect(listed.standardOutput.contains("No active projects"))

            let all = await world.run(["project", "list", "--all"])
            #expect(all.standardOutput.contains("PROJ"))
        }
    }

    @Test("archive requires --yes off a terminal")
    func archiveRequiresYesOffATerminal() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "archive", "PROJ"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--yes"))
        }
    }

    /// Unarchiving must not confirm: it is not destructive, and a prompt would
    /// make undoing a mistake harder than making one.
    @Test("unarchiving needs no confirmation")
    func unarchivingNeedsNoConfirmation() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["project", "archive", "PROJ", "--yes"])

            let result = await world.run(["project", "archive", "PROJ", "--undo"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))

            let listed = await world.run(["project", "list"])
            #expect(listed.standardOutput.contains("PROJ"))
        }
    }
}

@Suite("label")
struct LabelCommandTests {

    @Test("create then list shows the label")
    func createThenListShowsTheLabel() async throws {
        try await withCLI { world in
            try world.authenticate()
            let created = await world.run(["label", "create", "bug"])
            #expect(created.code == 0, Comment(rawValue: created.standardError))

            let listed = await world.run(["label", "list"])
            #expect(listed.standardOutput.contains("bug"))
        }
    }

    /// The same name must always get the same colour, or a label created
    /// independently on two machines would flicker between shades as they sync.
    @Test("an omitted colour is derived from the name")
    func omittedColourIsDerivedFromTheName() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let listed = await world.run(["label", "list", "--json"])
            let labels = try JSONCoders.decoder.decode(
                [Label].self, from: Data(listed.standardOutput.utf8))
            #expect(labels.first?.color == Label.defaultColor(forName: "bug"))
        }
    }

    @Test("an explicit colour is used")
    func explicitColourIsUsed() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug", "--color", "#123ABC"])

            let listed = await world.run(["label", "list", "--json"])
            let labels = try JSONCoders.decoder.decode(
                [Label].self, from: Data(listed.standardOutput.utf8))
            #expect(labels.first?.color == "#123ABC")
        }
    }

    @Test("a malformed colour is rejected before any request")
    func malformedColourIsRejected() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["label", "create", "bug", "--color", "banana"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("#2D6CDF"))
        }
    }

    @Test("edit renames a label")
    func editRenamesALabel() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let result = await world.run(["label", "edit", "bug", "--new-name", "defect"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))

            let listed = await world.run(["label", "list", "--quiet"])
            #expect(listed.standardOutput.contains("defect"))
        }
    }

    @Test("delete removes a label")
    func deleteRemovesALabel() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let result = await world.run(["label", "delete", "bug", "--yes"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))

            let listed = await world.run(["label", "list"])
            #expect(!listed.standardOutput.contains("bug"))
        }
    }

    @Test("delete requires --yes off a terminal")
    func deleteRequiresYesOffATerminal() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let result = await world.run(["label", "delete", "bug"])
            #expect(result.code == 2)

            let listed = await world.run(["label", "list", "--quiet"])
            #expect(listed.standardOutput.contains("bug"))
        }
    }

    @Test("an unknown label lists the known ones")
    func unknownLabelListsKnownOnes() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let result = await world.run(["label", "delete", "buhg", "--yes"])
            #expect(result.code != 0)
            #expect(result.standardError.contains("bug"))
        }
    }

    @Test("an empty project reports no labels rather than an empty table")
    func emptyProjectReportsNoLabels() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["label", "list"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("No labels"))
        }
    }

    @Test("no project names all the ways to set one")
    func noProjectNamesAllTheWays() async throws {
        try await withCLI(configuresProject: false) { world in
            try world.authenticate()
            let result = await world.run(["label", "list"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--project"))
        }
    }
}

@Suite("user")
struct UserCommandTests {

    @Test("me reports the authenticated user")
    func meReportsTheAuthenticatedUser() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["user", "me"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("saqib@example.com"))
            #expect(result.standardOutput.contains("admin"))
        }
    }

    @Test("list shows users")
    func listShowsUsers() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["user", "list"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("saqib@example.com"))
        }
    }

    @Test("show accepts an email address")
    func showAcceptsAnEmailAddress() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["user", "show", "saqib@example.com"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("Saqib"))
        }
    }

    /// A created account has no password, so it cannot log in. Saying so is the
    /// difference between an account that looks ready and one that is.
    @Test("create says the account cannot log in yet")
    func createSaysTheAccountCannotLogInYet() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["user", "create", "new@example.com"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("cannot log in yet"))
            #expect(result.standardOutput.contains("issues user password"))
        }
    }

    @Test("create rejects a malformed email before any request")
    func createRejectsAMalformedEmail() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["user", "create", "not-an-email"])
            #expect(result.code == 2)
        }
    }

    @Test("create rejects an unknown role")
    func createRejectsAnUnknownRole() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["user", "create", "new@example.com", "--role", "superuser"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("member, admin"))
        }
    }

    /// The whole point of the new endpoint: an Admin can make a created account
    /// usable.
    @Test("an admin sets a password and the user can then log in")
    func adminSetsAPasswordAndUserCanLogIn() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["user", "create", "new@example.com"])

            let set = await world.run(
                ["user", "password", "new@example.com"],
                isInputTerminal: true,
                secrets: ["a brand new secret", "a brand new secret"])
            #expect(set.code == 0, Comment(rawValue: set.standardError))

            _ = await world.run(["auth", "logout"])
            let login = await world.run(
                ["auth", "login", "--email", "new@example.com"],
                isInputTerminal: true, secrets: ["a brand new secret"])
            #expect(login.code == 0, Comment(rawValue: login.standardError))
        }
    }

    /// A mistyped password nobody can see is an account locked out by a typo.
    @Test("a mismatched repeat changes nothing")
    func mismatchedRepeatChangesNothing() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["user", "create", "new@example.com"])

            let result = await world.run(
                ["user", "password", "new@example.com"],
                isInputTerminal: true,
                secrets: ["a brand new secret", "a different secret"])

            #expect(result.code != 0)
            #expect(result.standardError.contains("did not match"))
        }
    }

    @Test("a password below the minimum length is refused before any request")
    func shortPasswordIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["user", "password", "saqib@example.com"],
                isInputTerminal: true, secrets: ["old", "short", "short"])
            #expect(result.code != 0)
        }
    }

    /// There is no --password flag on purpose, so off a terminal this must fail
    /// rather than find some other way to read one.
    @Test("setting a password off a terminal explains why there is no flag")
    func settingAPasswordOffATerminalExplains() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["user", "password", "saqib@example.com"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("shell history"))
        }
    }

    /// Our own token is revoked by the change, so leaving it stored would make the
    /// next command fail with a confusing 401.
    @Test("changing your own password clears the stored credential")
    func changingYourOwnPasswordClearsTheCredential() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["user", "password"],
                isInputTerminal: true,
                secrets: [CLIWorld.password, "a replacement secret", "a replacement secret"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("auth login"))
            let stored = try world.credentials.token(forServer: "https://issues.example.test")
            #expect(stored == nil)
        }
    }

    @Test("deactivate ends the user's sessions")
    func deactivateEndsSessions() async throws {
        try await withCLI { world in
            try world.authenticate()
            let member = DomainUser.fixture(email: "member@example.com", displayName: "Mel")
            try UserRepository(database: world.database).save(member)
            let session = try SessionRepository(database: world.database).create(
                for: member.id, kind: .human, deviceId: nil)

            let result = await world.run(
                ["user", "deactivate", "member@example.com", "--yes"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))

            let stillValid = try SessionRepository(database: world.database)
                .authenticate(session.raw)
            #expect(stillValid == nil, "a deactivated user's session still works")
        }
    }

    @Test("deactivate requires --yes off a terminal")
    func deactivateRequiresYesOffATerminal() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["user", "deactivate", "saqib@example.com"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--yes"))
        }
    }

    @Test("a deactivated user is hidden unless --all")
    func deactivatedUserIsHiddenUnlessAll() async throws {
        try await withCLI { world in
            try world.authenticate()
            let member = DomainUser.fixture(email: "member@example.com", displayName: "Mel")
            try UserRepository(database: world.database).save(member)
            _ = await world.run(["user", "deactivate", "member@example.com", "--yes"])

            let listed = await world.run(["user", "list", "--quiet"])
            #expect(!listed.standardOutput.contains("member@example.com"))

            let all = await world.run(["user", "list", "--all", "--quiet"])
            #expect(all.standardOutput.contains("member@example.com"))
        }
    }
}

@Suite("noun command output and edges")
struct NounOutputTests {

    /// The JSON path is separate code from the table path in each command, so
    /// covering one covers nothing about the other.
    @Test(
        "--json emits the API payload for each noun",
        arguments: [
            ["project", "list"],
            ["user", "list"],
            ["label", "list"],
            ["user", "me"],
            ["user", "show", "saqib@example.com"],
            ["project", "show", "PROJ"],
        ])
    func jsonEmitsTheAPIPayload(_ arguments: [String]) async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(arguments + ["--json"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            // Parses as JSON, and is not a reshaped CLI schema.
            _ = try JSONSerialization.jsonObject(
                with: Data(result.standardOutput.utf8), options: [.fragmentsAllowed])
        }
    }

    @Test(
        "--quiet emits bare identifiers for each noun",
        arguments: [
            (["user", "me"], "saqib@example.com"),
            (["user", "show", "saqib@example.com"], "saqib@example.com"),
            (["project", "show", "PROJ"], "PROJ"),
        ])
    func quietEmitsBareIdentifiers(arguments: [String], expected: String) async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(arguments + ["--quiet"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(
                result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        }
    }

    @Test("label edit changes a colour")
    func labelEditChangesAColour() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let result = await world.run(["label", "edit", "bug", "--color", "#123ABC"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))

            let listed = await world.run(["label", "list", "--json"])
            let labels = try JSONCoders.decoder.decode(
                [Label].self, from: Data(listed.standardOutput.utf8))
            #expect(labels.first?.color == "#123ABC")
        }
    }

    @Test("label edit rejects a malformed colour before any request")
    func labelEditRejectsAMalformedColour() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let result = await world.run(["label", "edit", "bug", "--color", "banana"])
            #expect(result.code == 2)
        }
    }

    @Test("a label edit that changes nothing is an error")
    func labelEditThatChangesNothingIsAnError() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(["label", "create", "bug"])

            let result = await world.run(["label", "edit", "bug"])
            #expect(result.code == 2)
            #expect(result.standardError.contains("--new-name"))
        }
    }

    /// `--password` at creation is the path that produces a usable account in one
    /// command, so it needs its own test rather than riding on the separate
    /// password command.
    @Test("user create --password produces an account that can log in")
    func createWithPasswordProducesAUsableAccount() async throws {
        try await withCLI { world in
            try world.authenticate()
            let created = await world.run(
                ["user", "create", "new@example.com", "--password"],
                isInputTerminal: true,
                secrets: ["a brand new secret", "a brand new secret"])

            #expect(created.code == 0, Comment(rawValue: created.standardError))
            #expect(!created.standardOutput.contains("cannot log in yet"))

            _ = await world.run(["auth", "logout"])
            let login = await world.run(
                ["auth", "login", "--email", "new@example.com"],
                isInputTerminal: true, secrets: ["a brand new secret"])
            #expect(login.code == 0, Comment(rawValue: login.standardError))
        }
    }

    /// Reading the password before creating means a cancelled prompt leaves no
    /// half-made account behind.
    @Test("a cancelled password prompt creates no account")
    func cancelledPasswordPromptCreatesNoAccount() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["user", "create", "new@example.com", "--password"],
                isInputTerminal: true, secrets: ["one secret", "a different secret"])

            #expect(result.code != 0)
            let listed = await world.run(["user", "list", "--all", "--quiet"])
            #expect(!listed.standardOutput.contains("new@example.com"))
        }
    }

    @Test("an empty password prompt is refused")
    func emptyPasswordPromptIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["user", "create", "new@example.com", "--password"],
                isInputTerminal: true, secrets: [""])
            #expect(result.code == 2)
        }
    }

    @Test("a project reference that is neither a key nor an id is refused")
    func projectReferenceThatIsNeitherIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "show", "not a key at all"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("project id"))
        }
    }

    @Test("an unknown project id is not found")
    func unknownProjectIdIsNotFound() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["project", "show", UUID().uuidString])
            #expect(result.code == 3)
        }
    }
}
