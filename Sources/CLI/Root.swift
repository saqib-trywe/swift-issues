import ArgumentParser

/// The root command.
///
/// The abstract documents the implied noun itself, because the rewrite happens
/// before ArgumentParser sees argv and so cannot appear in generated help.
struct Root: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "issues",
        abstract: "A lightweight, self-hosted issue tracker.",
        discussion: """
            `issue` is the implied noun, so `issues list` means `issues issue list`, \
            and `issues show PROJ-142` means `issues issue show PROJ-142`. The long \
            form always works.

            Output: the human-readable format is not a stable interface and may \
            change between releases. Use --json for anything a script depends on; \
            it emits the API payload verbatim.
            """,
        version: IssuesCLI.version,
        subcommands: [
            AuthCommand.self,
            IssueCommand.self,
            ConfigCommand.self,
        ]
    )

    /// The nouns argv may already start with.
    ///
    /// Derived from the declared subcommands rather than listed again, so adding a
    /// noun cannot forget to teach the rewrite about it. `help` is ArgumentParser's
    /// own and is not in `subcommands`.
    static var knownCommandNames: Set<String> {
        Set(configuration.subcommands.map { $0._commandName } + ["help"])
    }
}
