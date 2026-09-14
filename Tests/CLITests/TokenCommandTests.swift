import Core
import Foundation
import Server
import TestSupport
import Testing

@testable import CLI

@Suite("auth token")
struct TokenCommandTests {

    @Test("create mints a token that works")
    func createMintsAWorkingToken() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["auth", "token", "create", "--kind", "agent", "--label", "mcp"],
                isInputTerminal: true, secrets: [CLIWorld.password])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("issues_pat_"))
            #expect(result.standardOutput.contains("only time it will be shown"))

            let listed = await world.run(["auth", "token", "list"])
            #expect(listed.standardOutput.contains("mcp"))
            #expect(listed.standardOutput.contains("agent"))
        }
    }

    /// `TOKEN=$(issues auth token create -q)` has to work, so --quiet prints the
    /// token and nothing else.
    @Test("--quiet prints only the token")
    func quietPrintsOnlyTheToken() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["auth", "token", "create", "--quiet", "--label", "ci"],
                isInputTerminal: true, secrets: [CLIWorld.password])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let printed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(printed.hasPrefix("issues_pat_"))
            #expect(!printed.contains("\n"))
        }
    }

    /// The minted token must actually authenticate — the point of the whole slice.
    @Test("a minted token authenticates")
    func mintedTokenAuthenticates() async throws {
        try await withCLI { world in
            try world.authenticate()
            let created = await world.run(
                ["auth", "token", "create", "--quiet", "--label", "ci"],
                isInputTerminal: true, secrets: [CLIWorld.password])
            let minted = created.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            let used = await world.run(
                ["auth", "status"], environment: ["ISSUES_TOKEN": minted])
            #expect(used.code == 0, Comment(rawValue: used.standardError))
            #expect(used.standardOutput.contains("user@example.com"))
        }
    }

    /// Without the password a leaked token could mint replacements, and revoking
    /// the original would leave them working.
    @Test("a wrong password mints nothing")
    func wrongPasswordMintsNothing() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["auth", "token", "create"], isInputTerminal: true, secrets: ["not it"])

            #expect(result.code == 4)
            let listed = await world.run(["auth", "token", "list", "--quiet"])
            #expect(listed.standardOutput.split(separator: "\n").count == 1)
        }
    }

    /// There is no --password flag, so off a terminal this must fail rather than
    /// find another way.
    @Test("creating off a terminal explains why there is no flag")
    func creatingOffATerminalExplains() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["auth", "token", "create"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("shell history"))
        }
    }

    @Test("an unknown kind is rejected before any request")
    func unknownKindIsRejected() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["auth", "token", "create", "--kind", "superuser"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("agentReadonly"))
        }
    }

    /// A label is what makes a revocation list mean anything, so its absence is
    /// worth a nudge — on stderr, so --json stays clean.
    @Test("creating without a label warns on stderr")
    func creatingWithoutALabelWarns() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["auth", "token", "create"], isInputTerminal: true, secrets: [CLIWorld.password])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardError.contains("--label"))
        }
    }

    @Test("list shows the current session")
    func listShowsTheCurrentSession() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["auth", "token", "list"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("cli tests"))
            #expect(result.standardOutput.contains("active"))
        }
    }

    /// A listing is read to decide what to revoke, so it must be safe to print,
    /// log and paste.
    @Test("a listing carries no token material")
    func listingCarriesNoTokenMaterial() async throws {
        try await withCLI { world in
            try world.authenticate()
            let stored = try #require(
                try world.credentials.token(forServer: "https://issues.example.test"))

            let result = await world.run(["auth", "token", "list", "--json"])
            #expect(!result.standardOutput.contains(stored))
        }
    }

    @Test("revoke by id stops that token working")
    func revokeByIdStopsThatToken() async throws {
        try await withCLI { world in
            try world.authenticate()
            let created = await world.run(
                ["auth", "token", "create", "--quiet", "--label", "doomed"],
                isInputTerminal: true, secrets: [CLIWorld.password])
            let minted = created.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            let listed = await world.run(["auth", "token", "list", "--json"])
            let summaries = try JSONCoders.decoder.decode(
                [SessionSummary].self, from: Data(listed.standardOutput.utf8))
            let doomed = try #require(summaries.first(where: { $0.label == "doomed" }))

            let revoked = await world.run(
                ["auth", "token", "revoke", doomed.id.rawValue.uuidString, "--yes"])
            #expect(revoked.code == 0, Comment(rawValue: revoked.standardError))

            let used = await world.run(["auth", "status"], environment: ["ISSUES_TOKEN": minted])
            #expect(used.code == 4)
        }
    }

    /// Typing a UUID to revoke something is miserable, so a label works when it is
    /// unambiguous.
    @Test("revoke accepts a label")
    func revokeAcceptsALabel() async throws {
        try await withCLI { world in
            try world.authenticate()
            _ = await world.run(
                ["auth", "token", "create", "--label", "doomed"],
                isInputTerminal: true, secrets: [CLIWorld.password])

            let result = await world.run(["auth", "token", "revoke", "doomed", "--yes"])
            #expect(result.code == 0, Comment(rawValue: result.standardError))

            let listed = await world.run(["auth", "token", "list"])
            #expect(listed.standardOutput.contains("revoked"))
        }
    }

    /// A label matching two tokens must never pick one for you.
    @Test("an ambiguous label is refused")
    func ambiguousLabelIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            for _ in 0..<2 {
                _ = await world.run(
                    ["auth", "token", "create", "--label", "ci"],
                    isInputTerminal: true, secrets: [CLIWorld.password])
            }

            let result = await world.run(["auth", "token", "revoke", "ci", "--yes"])
            #expect(result.code != 0)
            #expect(result.standardError.contains("matches 2 tokens"))
        }
    }

    @Test("an unknown label or id is refused")
    func unknownLabelOrIdIsRefused() async throws {
        try await withCLI { world in
            try world.authenticate()
            let byLabel = await world.run(["auth", "token", "revoke", "nothing", "--yes"])
            #expect(byLabel.code != 0)
            #expect(byLabel.standardError.contains("auth token list"))

            let byId = await world.run(["auth", "token", "revoke", UUID().uuidString, "--yes"])
            #expect(byId.code == 3)
        }
    }

    /// Revocation is not undoable, so it confirms — and off a terminal there is
    /// nobody to ask.
    @Test("revoke requires --yes off a terminal")
    func revokeRequiresYesOffATerminal() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["auth", "token", "revoke", "cli tests"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("--yes"))

            let listed = await world.run(["auth", "token", "list"])
            #expect(!listed.standardOutput.contains("revoked"))
        }
    }

    @Test("declining the confirmation revokes nothing")
    func decliningRevokesNothing() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["auth", "token", "revoke", "cli tests"], isInputTerminal: true, input: ["n"])

            #expect(result.code != 0)
            let listed = await world.run(["auth", "token", "list"])
            #expect(!listed.standardOutput.contains("revoked"))
        }
    }

    /// The confirmation names the label, because an id alone gives you nothing to
    /// notice you have the wrong token.
    @Test("the confirmation names the token")
    func confirmationNamesTheToken() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["auth", "token", "revoke", "cli tests"], isInputTerminal: true, input: ["y"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            // On stderr, with the rest of the prompt.
            #expect(result.standardError.contains("cli tests"))
        }
    }

    @Test("an admin can list another user's tokens")
    func adminCanListAnotherUsersTokens() async throws {
        try await withCLI { world in
            try world.authenticate()
            let member = DomainUser.fixture(email: "member@example.com", displayName: "Mel")
            try UserRepository(database: world.database).save(member)
            _ = try SessionRepository(database: world.database).create(
                for: member.id, kind: .human, deviceId: nil, label: "their laptop")

            let result = await world.run(
                ["auth", "token", "list", "--user", "member@example.com"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("their laptop"))
        }
    }

    @Test("a member cannot list another user's tokens")
    func memberCannotListAnotherUsersTokens() async throws {
        try await withCLI { world in
            try world.authenticateAsMember()
            let result = await world.run(
                ["auth", "token", "list", "--user", "user@example.com"])
            #expect(result.code == 4)
        }
    }
}

@Suite("auth token edges")
struct TokenCommandEdgeTests {

    @Test("an empty listing says so rather than printing an empty table")
    func emptyListingSaysSo() async throws {
        try await withCLI { world in
            try world.authenticate()
            let member = DomainUser.fixture(email: "member@example.com", displayName: "Mel")
            try UserRepository(database: world.database).save(member)

            let result = await world.run(
                ["auth", "token", "list", "--user", "member@example.com"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(result.standardOutput.contains("No tokens."))
        }
    }

    @Test("--json emits the API payload")
    func jsonEmitsTheAPIPayload() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["auth", "token", "list", "--json"])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let items = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
            let array = try #require(items as? [[String: Any]])
            #expect(array.first?["kind"] as? String == "human")
            #expect(array.first?["id"] != nil)
        }
    }

    /// Creating with --json has to emit the token too, or the machine-readable
    /// form would be the one that loses the secret.
    @Test("create --json includes the token")
    func createJSONIncludesTheToken() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(
                ["auth", "token", "create", "--json", "--label", "ci"],
                isInputTerminal: true, secrets: [CLIWorld.password])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            let issued = try JSONCoders.decoder.decode(
                TokenIssued.self, from: Data(result.standardOutput.utf8))
            #expect(issued.token.hasPrefix("issues_pat_"))
            #expect(issued.session.label == "ci")
        }
    }
}
