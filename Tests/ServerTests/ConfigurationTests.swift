import Foundation
import Testing

@testable import Server

@Suite("Server configuration")
struct ServerConfigurationTests {

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "issues-config-\(UUID().uuidString).toml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("defaults apply with no file and no environment")
    func defaultsApply() throws {
        let config = try ServerConfiguration.load(file: nil, environment: [:])

        // Ticket 09: loopback by default, so the server cannot be exposed to a
        // network in cleartext by an admin who has not set up a proxy yet.
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8080)
        #expect(config.allowInsecure == false)
    }

    @Test("values come from the file when present")
    func fileValuesApply() throws {
        let url = try temporaryFile(
            """
            # The reverse proxy terminates TLS, so this stays on loopback.
            host = "127.0.0.1"
            port = 9090
            allowInsecure = true
            instanceName = "Trywe"
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try ServerConfiguration.load(file: url, environment: [:])

        #expect(config.port == 9090)
        #expect(config.allowInsecure)
        #expect(config.instanceName == "Trywe")
    }

    /// Precedence is env > file > defaults. Env exists for secrets and for scripted
    /// deploys, which must be able to override a file baked into an image.
    @Test("the environment overrides the file")
    func environmentOverridesFile() throws {
        let url = try temporaryFile(
            """
            port = 9090
            host = "127.0.0.1"
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try ServerConfiguration.load(
            file: url, environment: ["ISSUES_PORT": "7000", "ISSUES_HOST": "0.0.0.0"])

        #expect(config.port == 7000)
        #expect(config.host == "0.0.0.0")
    }

    @Test("comments and blank lines are ignored")
    func commentsAndBlankLinesIgnored() throws {
        let url = try temporaryFile(
            """
            # leading comment

            port = 9090   # trailing comment

            """)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try ServerConfiguration.load(file: url, environment: [:]).port == 9090)
    }

    /// The important behaviour. This reads a **subset** of TOML, and silently
    /// skipping syntax it does not understand would let an admin believe a setting
    /// applied when it did not — which for `allowInsecure` would mean serving bearer
    /// tokens in cleartext while believing otherwise.
    @Test(
        "unsupported syntax is refused rather than skipped",
        arguments: [
            "[server]\nport = 9090",
            "ports = [1, 2, 3]",
            "port = 9090\nhost",
            "= 9090",
            "port : 9090",
        ]
    )
    func unsupportedSyntaxIsRefused(contents: String) throws {
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try ServerConfiguration.load(file: url, environment: [:])
        }
    }

    @Test("an unknown key is refused, because a typo would otherwise be silent")
    func unknownKeyIsRefused() throws {
        let url = try temporaryFile(#"prot = 9090"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try ServerConfiguration.load(file: url, environment: [:])
        }
    }

    @Test("a non-numeric port is refused", arguments: ["port = \"nine thousand\"", "port = true"])
    func nonNumericPortIsRefused(contents: String) throws {
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try ServerConfiguration.load(file: url, environment: [:])
        }
    }

    @Test("a missing file is not an error — defaults simply apply")
    func missingFileIsNotAnError() throws {
        let absent = FileManager.default.temporaryDirectory
            .appending(path: "issues-absent-\(UUID().uuidString).toml")

        let config = try ServerConfiguration.load(file: absent, environment: [:])
        #expect(config.port == 8080)
    }

    /// `config validate` exists because a TOML typo that surfaces only as an agent
    /// that will not start is miserable to diagnose through launchd (ticket 09).
    @Test("validation reports the problem rather than throwing at startup")
    func validationReportsTheProblem() throws {
        let url = try temporaryFile("prot = 9090")
        defer { try? FileManager.default.removeItem(at: url) }

        let report: String = ServerConfiguration.validate(file: url)

        #expect(report.contains("prot"))
    }

    @Test("validation reports success for a good file")
    func validationReportsSuccess() throws {
        let url = try temporaryFile("port = 9090")
        defer { try? FileManager.default.removeItem(at: url) }

        let report: String = ServerConfiguration.validate(file: url)

        #expect(report.contains("valid"))
        #expect(report.contains("9090"))
    }

    /// A wrong type must be refused rather than coerced. Coercing `allowInsecure`
    /// from anything truthy would be the worst possible place to be lenient.
    @Test(
        "a value of the wrong type is refused",
        arguments: [
            "host = 123",
            "allowInsecure = \"yes\"",
            "instanceName = 5",
        ]
    )
    func wrongTypeIsRefused(contents: String) throws {
        let url = try temporaryFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try ServerConfiguration.load(file: url, environment: [:])
        }
    }

    /// A `#` inside a quoted string is not a comment — a colour like "#2D6CDF" has
    /// to survive, and truncating it would corrupt the value silently.
    @Test("a hash inside a quoted string is not treated as a comment")
    func hashInsideQuotesSurvives() throws {
        let url = try temporaryFile(#"instanceName = "Trywe #1""#)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try ServerConfiguration.load(file: url, environment: [:])
        #expect(config.instanceName == "Trywe #1")
    }
}

/// Where the server keeps its files.
@Suite("Application support location")
struct ApplicationSupportTests {

    /// `URL.applicationSupportDirectory` reads the password database and ignores
    /// `$HOME`, so without this a smoke test against a throwaway instance writes
    /// into the operator's real one. Found by doing exactly that.
    @Test("HOME is honoured when set")
    func homeIsHonouredWhenSet() {
        let support = ServerEntryPoint.applicationSupport(environment: ["HOME": "/tmp/sandbox"])
        #expect(support.path == "/tmp/sandbox/Library/Application Support")

        let database = ServerEntryPoint.databaseURL(applicationSupport: support)
        #expect(database.path == "/tmp/sandbox/Library/Application Support/Issues/issues.sqlite")
    }

    @Test(
        "an unset or empty HOME falls back to the account's directory",
        arguments: [
            [String: String](),
            ["HOME": ""],
        ])
    func unsetHomeFallsBack(_ environment: [String: String]) {
        #expect(
            ServerEntryPoint.applicationSupport(environment: environment)
                == URL.applicationSupportDirectory)
    }

    /// Every file the server owns lives in one directory, so an operator has one
    /// thing to back up and one thing to lock down.
    @Test("the database, config and token file share a directory")
    func filesShareADirectory() {
        let support = ServerEntryPoint.applicationSupport(environment: ["HOME": "/tmp/sandbox"])
        let parents = Set(
            [
                ServerEntryPoint.databaseURL(applicationSupport: support),
                ServerEntryPoint.configurationURL(applicationSupport: support),
                ServerEntryPoint.bootstrapTokenURL(applicationSupport: support),
            ].map { $0.deletingLastPathComponent().path })

        #expect(parents.count == 1)
    }
}
