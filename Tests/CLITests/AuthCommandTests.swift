import Core
import Foundation
import Server
import TestSupport
import Testing

@testable import CLI

/// These run the CLI against a real router, a real session store and a real
/// password hash, so what they prove is that the whole contract works — not that
/// the CLI agrees with a fixture somebody wrote by hand.
@Suite("auth")
struct AuthCommandTests {

    @Test("login stores a token that later commands can use")
    func loginStoresAUsableToken() async throws {
        try await withCLI { world in
            let result = await world.run(
                ["auth", "login", "--email", "user@example.com"],
                isInputTerminal: true,
                secrets: [CLIWorld.password])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("Logged in"))

            let stored = try world.credentials.token(forServer: "https://issues.example.test")
            #expect(stored != nil)

            // The real proof: the stored token authenticates a later command.
            let status = await world.run(["auth", "status"])
            #expect(status.code == 0)
            #expect(status.standardOutput.contains("user@example.com"))
        }
    }

    /// Ticket 07 throttles by account and returns identical bodies for a wrong
    /// password and an unknown one. The CLI must not undo that by saying
    /// something different in each case.
    @Test("a wrong password and an unknown account read the same")
    func wrongPasswordAndUnknownAccountReadTheSame() async throws {
        try await withCLI { world in
            let wrong = await world.run(
                ["auth", "login", "--email", "user@example.com"],
                isInputTerminal: true, secrets: ["not the password"])
            let unknown = await world.run(
                ["auth", "login", "--email", "nobody@example.com"],
                isInputTerminal: true, secrets: ["not the password"])

            #expect(wrong.code == 4)
            #expect(unknown.code == 4)
            #expect(
                wrong.standardError == unknown.standardError,
                "the CLI reveals which accounts exist, which the server went out of its way not to")
        }
    }

    /// Silently minting a token per invocation is what produces the sprawl that
    /// makes an Admin's revocation list useless.
    @Test("login leaves an existing session alone")
    func loginLeavesAnExistingSessionAlone() async throws {
        try await withCLI { world in
            try world.authenticate()
            let before = try world.credentials.token(forServer: "https://issues.example.test")

            let result = await world.run(["auth", "login", "--email", "user@example.com"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("Already logged in"))
            #expect(try world.credentials.token(forServer: "https://issues.example.test") == before)
        }
    }

    @Test("--force replaces an existing session")
    func forceReplacesAnExistingSession() async throws {
        try await withCLI { world in
            try world.authenticate()
            let before = try world.credentials.token(forServer: "https://issues.example.test")

            let result = await world.run(
                ["auth", "login", "--email", "user@example.com", "--force"],
                isInputTerminal: true, secrets: [CLIWorld.password])

            #expect(result.code == 0)
            #expect(try world.credentials.token(forServer: "https://issues.example.test") != before)
        }
    }

    /// A CI job that blocks on a prompt it cannot show looks like a hang, not a
    /// mistake, so the failure has to name what was missing.
    @Test("login fails by name rather than prompting off a terminal")
    func loginFailsByNameOffATerminal() async throws {
        try await withCLI { world in
            let result = await world.run(["auth", "login"], isInputTerminal: false)

            #expect(result.code == 2)
            #expect(result.standardError.contains("--email"))
            #expect(result.standardError.contains("stdin is not a terminal"))
        }
    }

    @Test("status without a credential says so and exits 4")
    func statusWithoutACredentialExitsFour() async throws {
        try await withCLI { world in
            let result = await world.run(["auth", "status"])

            #expect(result.code == 4)
            #expect(result.standardOutput.contains("none stored"))
            #expect(result.standardError.contains("issues auth login"))
        }
    }

    @Test("status reports identity, role and instance")
    func statusReportsIdentity() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["auth", "status"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("Example User"))
            #expect(result.standardOutput.contains("admin"))
            #expect(result.standardOutput.contains("Instance:"))
        }
    }

    /// The CI path: a token in the environment is used and never written to disk.
    @Test("ISSUES_TOKEN is used and leaves nothing behind")
    func environmentTokenLeavesNothingBehind() async throws {
        try await withCLI { world in
            let session = try SessionRepository(database: world.database).create(
                for: world.owner.id, kind: .human, deviceId: nil, label: "env")

            let result = await world.run(
                ["auth", "status"], environment: ["ISSUES_TOKEN": session.raw])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("ISSUES_TOKEN"))
            #expect(
                try world.credentials.token(forServer: "https://issues.example.test") == nil,
                "an environment token was written to disk, which the CI path must never do")
        }
    }

    @Test("logout removes the stored token")
    func logoutRemovesTheStoredToken() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["auth", "logout"])

            #expect(result.code == 0)
            #expect(try world.credentials.token(forServer: "https://issues.example.test") == nil)
        }
    }

    @Test("logout when not logged in is not an error")
    func logoutWhenNotLoggedInIsNotAnError() async throws {
        try await withCLI { world in
            let result = await world.run(["auth", "logout"])
            #expect(result.code == 0)
            #expect(result.standardOutput.contains("Not logged in"))
        }
    }

    /// Credentials are keyed by server so a test instance cannot clobber a real
    /// one — the reason ticket 11 asked for keying in the first place.
    @Test("logging out of one server leaves another's token alone")
    func logoutIsPerServer() async throws {
        try await withCLI { world in
            try world.authenticate()
            try world.credentials.store("issues_pat_other", forServer: "https://other.example.test")

            _ = await world.run(["auth", "logout"])

            #expect(
                try world.credentials.token(forServer: "https://other.example.test") == "issues_pat_other")
        }
    }
}

@Suite("auth server selection and prompting")
struct AuthServerSelectionTests {

    /// Pointing at a test instance must not need the config file changed first.
    @Test("--server targets a different instance")
    func serverTargetsADifferentInstance() async throws {
        try await withCLI { world in
            let result = await world.run(
                [
                    "auth", "login", "--server", "https://other.example.test",
                    "--email", "user@example.com",
                ],
                isInputTerminal: true, secrets: [CLIWorld.password])

            #expect(result.code == 0)
            let other = try world.credentials.token(forServer: "https://other.example.test")
            let configured = try world.credentials.token(forServer: "https://issues.example.test")
            #expect(other != nil)
            #expect(configured == nil, "logging in to one server wrote a credential for another")
        }
    }

    @Test(
        "--server rejects something that is not a URL",
        arguments: [
            ["auth", "login", "--server", "not a url"],
            ["auth", "logout", "--server", "not a url"],
        ])
    func serverRejectsNonsense(_ arguments: [String]) async throws {
        try await withCLI { world in
            let result = await world.run(arguments, isInputTerminal: true, secrets: ["x"])
            #expect(result.code == 2)
        }
    }

    @Test("logout --server targets a different instance")
    func logoutServerTargetsADifferentInstance() async throws {
        try await withCLI { world in
            try world.authenticate()
            try world.credentials.store("issues_pat_other", forServer: "https://other.example.test")

            let result = await world.run(["auth", "logout", "--server", "https://other.example.test"])

            #expect(result.code == 0)
            let removed = try world.credentials.token(forServer: "https://other.example.test")
            let kept = try world.credentials.token(forServer: "https://issues.example.test")
            #expect(removed == nil)
            #expect(kept != nil)
        }
    }

    @Test("the email is prompted for on a terminal")
    func emailIsPromptedForOnATerminal() async throws {
        try await withCLI { world in
            let result = await world.run(
                ["auth", "login"],
                isInputTerminal: true,
                input: ["user@example.com"],
                secrets: [CLIWorld.password])

            #expect(result.code == 0)
            // On stderr: a prompt is not program output.
            #expect(result.standardError.contains("Email:"))
            #expect(result.standardOutput.contains("Logged in"))
        }
    }

    @Test("an empty prompted email fails by name")
    func emptyPromptedEmailFailsByName() async throws {
        try await withCLI { world in
            let result = await world.run(["auth", "login"], isInputTerminal: true, input: [""])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--email"))
        }
    }

    @Test("an empty password fails rather than being sent")
    func emptyPasswordFails() async throws {
        try await withCLI { world in
            let result = await world.run(
                ["auth", "login", "--email", "user@example.com"],
                isInputTerminal: true, secrets: [""])
            #expect(result.code == 2)
        }
    }

    /// A token that no longer works is not a session worth protecting, so login
    /// proceeds instead of reporting a session that would fail on the next call.
    @Test("a stale stored token does not block a fresh login")
    func staleTokenDoesNotBlockLogin() async throws {
        try await withCLI { world in
            try world.credentials.store("issues_pat_revoked", forServer: "https://issues.example.test")

            let result = await world.run(
                ["auth", "login", "--email", "user@example.com"],
                isInputTerminal: true, secrets: [CLIWorld.password])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("Logged in"))
            let stored = try world.credentials.token(forServer: "https://issues.example.test")
            #expect(stored != "issues_pat_revoked")
        }
    }

    /// A trailing slash or a path must not produce a second, invisible credential
    /// that later reads as "not logged in".
    @Test(
        "credentials key on the origin, not the exact URL",
        arguments: [
            "https://issues.example.test",
            "https://issues.example.test/",
            "https://issues.example.test/api",
        ])
    func credentialsKeyOnTheOrigin(_ raw: String) {
        let url = URL(string: raw)!
        #expect(CommandContext.credentialKey(for: url) == "https://issues.example.test")
    }
}
