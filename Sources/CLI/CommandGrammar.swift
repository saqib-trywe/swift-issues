/// Rewrites argv so `issue` can be the implied noun.
///
/// Ticket 11 wants `issues list` to mean `issues issue list`, because the
/// unabbreviated form stutters on the commonest command anyone types.
/// ArgumentParser has no default-subcommand feature, so the rewrite happens
/// before parsing rather than inside it.
///
/// Kept a pure function over `[String]` on purpose: the parser is hard to drive
/// from a test, and this is the part with the edge cases.
enum CommandGrammar {

    /// Inserts `issue` before the first token that looks like a verb.
    ///
    /// `knownCommands` is passed in rather than hard-coded so it can be derived
    /// from the root command's own subcommands — a second hand-maintained list
    /// would drift the moment a noun is added.
    static func expandingDefaultNoun(
        _ arguments: [String],
        knownCommands: Set<String>,
        impliedNoun: String = "issue"
    ) -> [String] {
        // The first token that is not a flag is the subcommand. Options that take
        // a separate value would break this assumption, so the root command
        // declares none; `RootCommandTests` holds that line.
        guard let index = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else {
            // No subcommand at all: `issues`, `issues --help`, `issues --version`.
            // Splicing a noun here would replace the top-level command list with
            // one noun's, which is the opposite of what someone asking for help
            // needs.
            return arguments
        }

        // `--` means "stop interpreting". Rewriting past it would corrupt the one
        // intent the user spelled out explicitly.
        if arguments[..<index].contains("--") { return arguments }

        guard !knownCommands.contains(arguments[index]) else { return arguments }

        var expanded = arguments
        expanded.insert(impliedNoun, at: index)
        return expanded
    }
}
