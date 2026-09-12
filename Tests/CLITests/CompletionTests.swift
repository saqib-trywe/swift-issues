import ArgumentParser
import Foundation
import Testing

@testable import CLI

/// Shell completion scripts.
///
/// ArgumentParser generates these, so what is worth testing is not the generator
/// but that our command surface produces a script each shell will actually load.
/// A broken completion script is worse than none: it prints errors on every shell
/// start-up.
@Suite("Completions")
struct CompletionTests {

    private let shells = ["zsh", "bash", "fish"]

    @Test("a script is produced for every supported shell", arguments: ["zsh", "bash", "fish"])
    func scriptIsProducedForEveryShell(_ shell: String) throws {
        let parsed = try #require(CompletionShell(rawValue: shell))
        let script = Root.completionScript(for: parsed)

        #expect(!script.isEmpty)
        #expect(script.contains("issues"))
    }

    /// The nouns have to appear, or completion silently offers nothing useful.
    @Test("the script mentions the top-level commands", arguments: ["zsh", "bash", "fish"])
    func scriptMentionsTopLevelCommands(_ shell: String) throws {
        let script = Root.completionScript(for: try #require(CompletionShell(rawValue: shell)))

        for noun in ["auth", "issue", "project", "label", "user", "config", "completion"] {
            #expect(script.contains(noun), "'\(noun)' is missing from the \(shell) script")
        }
    }

    /// The enum values are the ones nobody remembers the spelling of — `inProgress`
    /// in particular — so they are exactly what completion is for.
    @Test("status and priority values are offered")
    func statusAndPriorityValuesAreOffered() throws {
        let script = Root.completionScript(for: .zsh)

        #expect(script.contains("inProgress"))
        #expect(script.contains("urgent"))
        #expect(script.contains("agentReadonly"))
    }

    /// The real check: a script a shell refuses to parse is worse than no script,
    /// because it errors on every shell start-up.
    ///
    /// zsh and bash ship with macOS, so these always run.
    @Test("each script parses in its own shell", arguments: ["zsh", "bash"])
    func eachScriptParsesInItsOwnShell(_ shell: String) throws {
        try Shells.check(shell)
    }

    /// fish is not installed by default, so this is skipped rather than failed on a
    /// machine without it — a red suite for a missing shell teaches people to
    /// ignore red suites.
    @Test(
        "the fish script parses",
        .enabled(if: Shells.locate("fish") != nil, "fish is not installed"))
    func fishScriptParses() throws {
        try Shells.check("fish")
    }
}

/// Runs a generated script through its shell's parser.
enum Shells {

    static func check(_ shell: String) throws {
        let executable = try #require(locate(shell), "\(shell) is not installed")
        let script = Root.completionScript(for: try #require(CompletionShell(rawValue: shell)))

        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issues-completion-\(UUID().uuidString).\(shell)")
        try Data(script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Parse-only in every case, so a completion script cannot touch the machine
        // running the tests.
        process.arguments = shell == "fish" ? ["--no-execute", file.path] : ["-n", file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let reported = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(
            process.terminationStatus == 0,
            Comment(rawValue: "\(shell) rejected the script:\n\(reported)"))
    }

    static func locate(_ shell: String) -> String? {
        [
            "/bin/\(shell)", "/usr/bin/\(shell)",
            "/opt/homebrew/bin/\(shell)", "/usr/local/bin/\(shell)",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@Suite("completion command")
struct CompletionCommandTests {

    @Test("the command prints a script to stdout", arguments: ["zsh", "bash", "fish"])
    func commandPrintsAScript(_ shell: String) async throws {
        try await withCLI { world in
            let result = await world.run(["completion", shell])

            #expect(result.code == 0, Comment(rawValue: result.standardError))
            #expect(!result.standardOutput.isEmpty)
            #expect(result.standardOutput.contains("issues"))
        }
    }

    /// The output is meant to be redirected into a file or `source`d, so anything
    /// else on stdout would corrupt it.
    @Test("nothing but the script goes to stdout")
    func nothingButTheScriptGoesToStdout() async throws {
        try await withCLI { world in
            let result = await world.run(["completion", "zsh"])
            #expect(result.standardOutput == Root.completionScript(for: .zsh) + "\n")
        }
    }

    /// Completions must work with no server, no token and no config — they are
    /// generated locally, and needing a login to install them would be absurd.
    @Test("completions need no server or credential")
    func completionsNeedNoServerOrCredential() async throws {
        try await withCLI(configuresProject: false) { world in
            let result = await world.run(
                ["completion", "zsh"], environment: ["ISSUES_NO_URL": "1"])
            #expect(result.code == 0)
        }
    }

    @Test("an unsupported shell is a usage error listing the supported ones")
    func unsupportedShellIsAUsageError() async throws {
        try await withCLI { world in
            let result = await world.run(["completion", "nushell"])

            #expect(result.code == 2)
            #expect(result.standardError.contains("zsh"))
            #expect(result.standardError.contains("fish"))
        }
    }

    @Test("the shell argument is required")
    func shellArgumentIsRequired() async throws {
        try await withCLI { world in
            let result = await world.run(["completion"])
            #expect(result.code == 2)
        }
    }

    /// `issues completion` must not be swallowed by the implied-noun rewrite, or it
    /// would become `issues issue completion`.
    @Test("completion is not rewritten as an issue verb")
    func completionIsNotRewrittenAsAnIssueVerb() {
        #expect(
            CommandGrammar.expandingDefaultNoun(
                ["completion", "zsh"], knownCommands: Root.knownCommandNames)
                == ["completion", "zsh"])
    }

    @Test("help explains how to install the script")
    func helpExplainsHowToInstall() async throws {
        try await withCLI { world in
            let result = await world.run(["completion", "--help"])

            #expect(result.code == 0)
            #expect(result.standardOutput.contains("source"))
        }
    }
}
