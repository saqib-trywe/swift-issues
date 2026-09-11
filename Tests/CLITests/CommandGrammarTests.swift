import Testing

@testable import CLI

/// Ticket 11 makes `issue` the implied noun, so `issues list` means
/// `issues issue list`. ArgumentParser has no native default subcommand, so this
/// rewrite happens before parsing — which means it must be right about every
/// shape of argv, including the ones that must be left alone.
@Suite("Command grammar")
struct CommandGrammarTests {

    private let nouns: Set<String> = [
        "auth", "issue", "project", "label", "user", "config", "completion", "help",
    ]

    private func expand(_ arguments: [String]) -> [String] {
        CommandGrammar.expandingDefaultNoun(arguments, knownCommands: nouns)
    }

    @Test("a bare verb gains the implied noun")
    func bareVerbGainsTheImpliedNoun() {
        #expect(expand(["list"]) == ["issue", "list"])
        #expect(expand(["show", "PROJ-142"]) == ["issue", "show", "PROJ-142"])
        #expect(expand(["close", "PROJ-1", "--yes"]) == ["issue", "close", "PROJ-1", "--yes"])
    }

    /// The long form has to keep working, or every script and every piece of
    /// documentation that spells the noun out breaks.
    @Test("an explicit noun is left alone")
    func explicitNounIsLeftAlone() {
        #expect(expand(["issue", "list"]) == ["issue", "list"])
        #expect(expand(["project", "list"]) == ["project", "list"])
        #expect(expand(["auth", "login"]) == ["auth", "login"])
        #expect(expand(["help"]) == ["help"])
    }

    /// Help must render without a network, a token, or a subcommand. Splicing a
    /// noun in here would turn `issues --help` into `issues issue --help` and
    /// hide the top-level command list — the one thing a new user needs.
    @Test(
        "argv with no subcommand is left alone",
        arguments: [
            [] as [String],
            ["--help"],
            ["-h"],
            ["--version"],
        ])
    func argvWithNoSubcommandIsLeftAlone(_ arguments: [String]) {
        #expect(expand(arguments) == arguments)
    }

    /// The noun goes where the verb is, not at the front, so any leading flag
    /// keeps its position relative to the parser.
    @Test("the noun is spliced at the first non-flag token")
    func nounIsSplicedAtTheFirstNonFlagToken() {
        #expect(expand(["--json", "list"]) == ["--json", "issue", "list"])
        #expect(expand(["-q", "list"]) == ["-q", "issue", "list"])
    }

    /// `--` is an explicit instruction to stop interpreting, so rewriting past it
    /// would corrupt exactly the intent the user spelled out.
    @Test("a literal separator suppresses the rewrite")
    func literalSeparatorSuppressesTheRewrite() {
        #expect(expand(["--", "list"]) == ["--", "list"])
    }

    /// An unknown word is treated as a verb rather than rejected here: the parser
    /// owns error messages, and it can say what `issue` accepts.
    @Test("an unknown word is treated as a verb")
    func unknownWordIsTreatedAsAVerb() {
        #expect(expand(["frobnicate"]) == ["issue", "frobnicate"])
    }
}
