import Core
import Foundation
import Testing

@testable import CLI

@Suite("CLI configuration")
struct CLIConfigurationTests {

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issues-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("a missing config file is not an error")
    func missingConfigFileIsNotAnError() throws {
        try withDirectory { directory in
            let configuration = try CLIConfiguration.load(
                file: directory.appending(path: "absent.toml"),
                workingDirectory: directory, environment: [:])
            #expect(configuration.serverURL == nil)
            #expect(configuration.defaultProject == nil)
        }
    }

    @Test("the config file supplies the server and project")
    func configFileSuppliesServerAndProject() throws {
        try withDirectory { directory in
            let file = directory.appending(path: "config.toml")
            try #"url = "https://issues.example.test""#.appending("\nproject = \"PROJ\"\n")
                .write(to: file, atomically: true, encoding: .utf8)

            let configuration = try CLIConfiguration.load(
                file: file, workingDirectory: directory, environment: [:])

            #expect(configuration.serverURL?.absoluteString == "https://issues.example.test")
            #expect(configuration.defaultProject?.wireValue == "PROJ")
        }
    }

    /// The CI path: environment beats a file baked into an image.
    @Test("ISSUES_URL overrides the file")
    func environmentOverridesTheFile() throws {
        try withDirectory { directory in
            let file = directory.appending(path: "config.toml")
            try #"url = "https://from-file.example.test""#
                .write(to: file, atomically: true, encoding: .utf8)

            let configuration = try CLIConfiguration.load(
                file: file, workingDirectory: directory,
                environment: ["ISSUES_URL": "https://from-env.example.test"])

            #expect(configuration.serverURL?.absoluteString == "https://from-env.example.test")
        }
    }

    @Test("a per-directory file supplies the default project")
    func perDirectoryFileSuppliesTheProject() throws {
        try withDirectory { directory in
            try "project = \"WEB\"\n".write(
                to: directory.appending(path: ".issues.toml"), atomically: true, encoding: .utf8)

            let configuration = try CLIConfiguration.load(
                file: nil, workingDirectory: directory, environment: [:])
            #expect(configuration.defaultProject?.wireValue == "WEB")
        }
    }

    /// A checkout maps to its Project from anywhere inside it, which is the whole
    /// reason the walk exists.
    @Test("the per-directory file is found from a subdirectory")
    func perDirectoryFileIsFoundFromASubdirectory() throws {
        try withDirectory { directory in
            try "project = \"WEB\"\n".write(
                to: directory.appending(path: ".issues.toml"), atomically: true, encoding: .utf8)
            let nested = directory.appending(path: "a/b/c")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            let configuration = try CLIConfiguration.load(
                file: nil, workingDirectory: nested, environment: [:])
            #expect(configuration.defaultProject?.wireValue == "WEB")
        }
    }

    /// `.issues.toml` is repository-controlled content. If a checkout could
    /// retarget the CLI at another host, `git clone` would be enough to redirect
    /// somebody's traffic.
    @Test("a per-directory file may not set the server")
    func perDirectoryFileMayNotSetTheServer() throws {
        try withDirectory { directory in
            try #"url = "https://attacker.example.test""#.write(
                to: directory.appending(path: ".issues.toml"), atomically: true, encoding: .utf8)

            #expect(throws: CLIError.self) {
                try CLIConfiguration.load(file: nil, workingDirectory: directory, environment: [:])
            }
        }
    }

    /// Silently skipping a key an admin wrote would leave them believing a setting
    /// applied when it had not.
    @Test("an unknown key is refused")
    func unknownKeyIsRefused() throws {
        try withDirectory { directory in
            let file = directory.appending(path: "config.toml")
            try "colour = \"blue\"\n".write(to: file, atomically: true, encoding: .utf8)

            #expect(throws: ConfigurationError.self) {
                try CLIConfiguration.load(file: file, workingDirectory: directory, environment: [:])
            }
        }
    }

    @Test(
        "a malformed value is refused",
        arguments: [
            #"url = "not a url""#,
            #"project = "lowercase""#,
            #"project = "WAY-TOO-LONG-FOR-A-KEY""#,
        ])
    func malformedValueIsRefused(_ contents: String) throws {
        try withDirectory { directory in
            let file = directory.appending(path: "config.toml")
            try contents.write(to: file, atomically: true, encoding: .utf8)

            #expect(throws: (any Error).self) {
                try CLIConfiguration.load(file: file, workingDirectory: directory, environment: [:])
            }
        }
    }

    @Test("XDG_CONFIG_HOME moves the config file")
    func xdgConfigHomeMovesTheFile() {
        let home = URL(fileURLWithPath: "/Users/example")
        let standard = CLIConfiguration.defaultFile(environment: [:], home: home)
        let moved = CLIConfiguration.defaultFile(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], home: home)

        #expect(standard.path == "/Users/example/.config/issues/config.toml")
        #expect(moved.path == "/tmp/xdg/issues/config.toml")
    }

    /// A config file is meant to be edited by hand, so rewriting one setting must
    /// not throw away the comments around it.
    @Test("writing a setting preserves comments and other settings")
    func writingASettingPreservesTheFile() throws {
        try withDirectory { directory in
            let file = directory.appending(path: "config.toml")
            try "# my server\nurl = \"https://old.example.test\"\nproject = \"PROJ\"\n"
                .write(to: file, atomically: true, encoding: .utf8)

            try ConfigurationWriter.write(key: "url", value: "https://new.example.test", to: file)
            let contents = try String(contentsOf: file, encoding: .utf8)

            #expect(contents.contains("# my server"))
            #expect(contents.contains("https://new.example.test"))
            #expect(!contents.contains("old.example.test"))
            #expect(contents.contains("project = \"PROJ\""))
        }
    }

    @Test("writing a setting creates the file and its directory")
    func writingCreatesTheFile() throws {
        try withDirectory { directory in
            let file = directory.appending(path: "nested/deeper/config.toml")
            try ConfigurationWriter.write(key: "project", value: "WEB", to: file)

            let configuration = try CLIConfiguration.load(
                file: file, workingDirectory: directory, environment: [:])
            #expect(configuration.defaultProject?.wireValue == "WEB")
        }
    }

    /// Repeated writes must not accumulate blank lines, or the file grows a
    /// trailing gap every time somebody changes a setting.
    @Test("repeated writes do not accumulate blank lines")
    func repeatedWritesDoNotAccumulateBlankLines() throws {
        try withDirectory { directory in
            let file = directory.appending(path: "config.toml")
            for index in 0..<5 {
                try ConfigurationWriter.write(key: "project", value: "P\(index)", to: file)
            }
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(contents == "project = \"P4\"\n")
        }
    }
}

@Suite("Credential storage")
struct CredentialStoreTests {

    private func withStore(_ body: (FileCredentialStore, URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issues-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "credentials")
        try body(FileCredentialStore(file: file), file)
    }

    @Test("a stored token comes back")
    func storedTokenComesBack() throws {
        try withStore { store, _ in
            try store.store("issues_pat_abc", forServer: "https://a.example.test")
            let stored = try store.token(forServer: "https://a.example.test")
            #expect(stored == "issues_pat_abc")
        }
    }

    @Test("an absent token is nil, not an error")
    func absentTokenIsNil() throws {
        try withStore { store, _ in
            let absent = try store.token(forServer: "https://nowhere.example.test")
            #expect(absent == nil)
        }
    }

    /// Ticket 11's reason for keying by server: pointing at a test instance must
    /// not clobber the credential for a real one.
    @Test("servers do not clobber each other")
    func serversDoNotClobberEachOther() throws {
        try withStore { store, _ in
            try store.store("token-a", forServer: "https://a.example.test")
            try store.store("token-b", forServer: "https://b.example.test")

            let a = try store.token(forServer: "https://a.example.test")
            let b = try store.token(forServer: "https://b.example.test")
            #expect(a == "token-a")
            #expect(b == "token-b")
        }
    }

    @Test("removing one server leaves the others")
    func removingOneServerLeavesTheOthers() throws {
        try withStore { store, _ in
            try store.store("token-a", forServer: "https://a.example.test")
            try store.store("token-b", forServer: "https://b.example.test")
            try store.remove(forServer: "https://a.example.test")

            let removed = try store.token(forServer: "https://a.example.test")
            let kept = try store.token(forServer: "https://b.example.test")
            #expect(removed == nil)
            #expect(kept == "token-b")
        }
    }

    @Test("removing something absent is not an error")
    func removingSomethingAbsentIsNotAnError() throws {
        try withStore { store, _ in
            try store.remove(forServer: "https://nowhere.example.test")
        }
    }

    /// A bearer token readable by every account on the machine is the failure this
    /// file format exists to avoid.
    @Test("the credentials file is not readable by anyone else")
    func credentialsFileIsNotGroupOrWorldReadable() throws {
        try withStore { store, file in
            try store.store("issues_pat_abc", forServer: "https://a.example.test")

            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue == 0o600)
        }
    }

    /// Rewriting must not widen the mode of a file that already existed.
    @Test("a rewrite keeps the mode")
    func rewriteKeepsTheMode() throws {
        try withStore { store, file in
            try store.store("first", forServer: "https://a.example.test")
            try store.store("second", forServer: "https://a.example.test")

            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue == 0o600)
            let reread = try store.token(forServer: "https://a.example.test")
            #expect(reread == "second")
        }
    }
}

@Suite("Home directory resolution")
struct HomeResolutionTests {

    /// `FileManager.homeDirectoryForCurrentUser` reads the password database and
    /// ignores `$HOME`, so without this a sandboxed run writes to the real home.
    /// Found by a smoke test that did exactly that.
    @Test("HOME is honoured when set")
    func homeIsHonouredWhenSet() {
        let resolved = CLIConfiguration.home(environment: ["HOME": "/tmp/sandbox"])
        #expect(resolved.path == "/tmp/sandbox")

        let file = CLIConfiguration.defaultFile(
            environment: ["HOME": "/tmp/sandbox"], home: resolved)
        #expect(file.path == "/tmp/sandbox/.config/issues/config.toml")
    }

    @Test(
        "an unset or empty HOME falls back to the account's home",
        arguments: [
            [String: String](),
            ["HOME": ""],
        ])
    func unsetHomeFallsBack(_ environment: [String: String]) {
        #expect(
            CLIConfiguration.home(environment: environment)
                == FileManager.default.homeDirectoryForCurrentUser)
    }

    /// XDG wins over HOME, since someone who set it was being specific.
    @Test("XDG_CONFIG_HOME still wins")
    func xdgStillWins() {
        let environment = ["HOME": "/tmp/sandbox", "XDG_CONFIG_HOME": "/tmp/xdg"]
        let file = CLIConfiguration.defaultFile(
            environment: environment, home: CLIConfiguration.home(environment: environment))
        #expect(file.path == "/tmp/xdg/issues/config.toml")
    }
}
