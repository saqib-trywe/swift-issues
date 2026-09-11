import Core
import Foundation
import Server
import TestSupport
import Testing

@testable import CLI

/// The top level: what argv turns into, where output goes, and what the process
/// exits with. All of it reachable because `run` returns a code rather than
/// calling `exit`.
@Suite("Dispatch")
struct DispatchTests {

    /// Help must render with no network, no token and no config. If it did not,
    /// a new user's very first command would fail.
    @Test("help works with nothing configured", arguments: [["--help"], ["help"]])
    func helpWorksWithNothingConfigured(_ arguments: [String]) async throws {
        try await withCLI { world in
            let result = await world.run(arguments, environment: ["ISSUES_NO_URL": "1"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("issues"))
            #expect(result.standardError.isEmpty)
        }
    }

    /// The rewrite happens before ArgumentParser sees argv, so generated help
    /// cannot mention it — the abstract has to, or it is undiscoverable.
    @Test("help documents the implied noun")
    func helpDocumentsTheImpliedNoun() async throws {
        try await withCLI { world in
            let result = await world.run(["--help"])
            #expect(result.standardOutput.contains("implied noun"))
        }
    }

    /// Ticket 11 requires this to be stated where someone will see it, not only in
    /// a document they will not read.
    @Test("help states that the human format is not stable")
    func helpStatesTheHumanFormatIsNotStable() async throws {
        try await withCLI { world in
            let result = await world.run(["--help"])
            #expect(result.standardOutput.contains("not a stable interface"))
            #expect(result.standardOutput.contains("--json"))
        }
    }

    @Test("--version prints the version to stdout and exits 0")
    func versionPrintsToStandardOutput() async throws {
        try await withCLI { world in
            let result = await world.run(["--version"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains(IssuesCLI.version))
        }
    }

    /// A published exit code: ArgumentParser's own default here is 64, and
    /// ticket 11 says 2.
    @Test("an unknown command is a usage error on stderr")
    func unknownCommandIsAUsageError() async throws {
        try await withCLI { world in
            let result = await world.run(["frobnicate"])

            #expect(result.code == 2)
            #expect(!result.standardError.isEmpty)
            #expect(result.standardOutput.isEmpty, "a failure must not pollute stdout")
        }
    }

    @Test("a missing required argument is a usage error")
    func missingRequiredArgumentIsAUsageError() async throws {
        try await withCLI { world in
            try world.authenticate()
            let result = await world.run(["show"])
            #expect(result.code == 2)
        }
    }

    /// Nothing works without a server, so the message has to say how to set one
    /// rather than reporting a failed connection.
    @Test("no configured server is a usage error naming the fix")
    func noConfiguredServerNamesTheFix() async throws {
        try await withCLI { world in
            let result = await world.run(["list"], environment: ["ISSUES_NO_URL": "1"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("issues config set url"))
            #expect(result.standardError.contains("ISSUES_URL"))
        }
    }

    /// Errors on stderr is what keeps `--json` on stdout safe to pipe into jq.
    @Test("errors never appear on stdout")
    func errorsNeverAppearOnStdout() async throws {
        try await withCLI { world in
            let result = await world.run(["list"])

            #expect(result.code == 4)
            #expect(result.standardOutput.isEmpty)
            #expect(!result.standardError.isEmpty)
        }
    }

    @Test("the known command names come from the declared subcommands")
    func knownCommandNamesComeFromSubcommands() {
        #expect(Root.knownCommandNames.contains("auth"))
        #expect(Root.knownCommandNames.contains("issue"))
        #expect(Root.knownCommandNames.contains("config"))
        #expect(Root.knownCommandNames.contains("help"))
    }
}

@Suite("config command")
struct ConfigCommandTests {

    @Test("set then get round-trips through the file")
    func setThenGetRoundTrips() async throws {
        try await withCLI { world in
            let set = await world.run(
                ["config", "set", "project", "WEB"], environment: ["ISSUES_NO_URL": "1"])
            #expect(set.code == 0)

            let get = await world.run(
                ["config", "get", "project"], environment: ["ISSUES_NO_URL": "1"])
            #expect(get.code == 0)
            #expect(get.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "WEB")
        }
    }

    /// Validated before writing, so a typo fails here rather than on every later
    /// command with a message about a file.
    @Test(
        "an invalid value is rejected before it is written",
        arguments: [
            ["config", "set", "project", "lowercase"],
            ["config", "set", "url", "not a url"],
            ["config", "set", "colour", "blue"],
        ])
    func invalidValueIsRejectedBeforeWriting(_ arguments: [String]) async throws {
        try await withCLI { world in
            let result = await world.run(arguments, environment: ["ISSUES_NO_URL": "1"])

            #expect(result.code == 2)
            #expect(
                !FileManager.default.fileExists(atPath: world.configurationFile.path),
                "a rejected value still created the config file")
        }
    }

    /// Otherwise the next command appears to ignore what was just set, and the
    /// reason is invisible.
    @Test("setting a url that the environment overrides warns on stderr")
    func settingAnOverriddenUrlWarns() async throws {
        try await withCLI { world in
            let result = await world.run(
                ["config", "set", "url", "https://new.example.test"],
                environment: ["ISSUES_URL": "https://env.example.test"])

            #expect(result.code == 0)
            #expect(result.standardError.contains("ISSUES_URL"))
        }
    }

    @Test("get reports the resolved value, not the file's")
    func getReportsTheResolvedValue() async throws {
        try await withCLI { world in
            _ = await world.run(
                ["config", "set", "url", "https://file.example.test"],
                environment: ["ISSUES_NO_URL": "1"])

            let result = await world.run(
                ["config", "get", "url"],
                environment: ["ISSUES_URL": "https://env.example.test"])

            #expect(result.standardOutput.contains("env.example.test"))
        }
    }

    @Test("path prints the config file location")
    func pathPrintsTheLocation() async throws {
        try await withCLI { world in
            let result = await world.run(["config", "path"], environment: ["ISSUES_NO_URL": "1"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains(world.configurationFile.path))
        }
    }

    @Test("getting an unset value fails rather than printing nothing")
    func gettingAnUnsetValueFails() async throws {
        try await withCLI { world in
            let result = await world.run(["config", "get", "project"], environment: ["ISSUES_NO_URL": "1"])
            #expect(result.code != 0)
        }
    }
}

@Suite("config command edges")
struct ConfigCommandEdgeTests {

    @Test("getting an unknown setting is a usage error naming the known ones")
    func gettingAnUnknownSettingIsAUsageError() async throws {
        try await withCLI { world in
            let result = await world.run(
                ["config", "get", "colour"], environment: ["ISSUES_NO_URL": "1"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("project"))
        }
    }

    /// `config path` has to show both files, or a surprising default project
    /// coming from a checkout is invisible.
    @Test("path shows a per-directory file when one applies")
    func pathShowsThePerDirectoryFile() async throws {
        try await withCLI { world in
            try "project = \"WEB\"\n".write(
                to: world.directory.appending(path: ".issues.toml"),
                atomically: true, encoding: .utf8)

            let result = await world.run(["config", "path"], environment: ["ISSUES_NO_URL": "1"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains(".issues.toml"))
        }
    }

    /// A per-directory project is the reason the walk exists: `issues list` inside
    /// a checkout should mean that checkout's project.
    @Test("a per-directory project is used by list")
    func perDirectoryProjectIsUsedByList() async throws {
        try await withCLI { world in
            try world.authenticate()
            try "project = \"\(world.project.key.wireValue)\"\n".write(
                to: world.directory.appending(path: ".issues.toml"),
                atomically: true, encoding: .utf8)
            _ = try IssueRepository(database: world.database).create(
                DomainIssue.fixture(
                    key: nil, projectId: world.project.id, title: "Scoped",
                    reporterId: world.owner.id))

            let result = await world.run(["list", "--quiet"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("PROJ-"))
        }
    }

    /// A bad value in the environment must name the variable, or it looks like the
    /// config file is at fault.
    @Test("a malformed ISSUES_URL names the variable")
    func malformedEnvironmentURLNamesTheVariable() async throws {
        try await withCLI { world in
            let result = await world.run(["list"], environment: ["ISSUES_URL": "not a url"])

            #expect(result.code != 0)
            #expect(result.standardError.contains("ISSUES_URL"))
        }
    }
}
