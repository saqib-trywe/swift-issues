import ArgumentParser
import Foundation

/// Prints a shell completion script.
///
/// ArgumentParser generates the script from the command surface itself, so
/// completions cannot drift from the commands the way a hand-written script
/// would. This wraps it as `issues completion <shell>` because that is what
/// ticket 11 specifies, and because the built-in
/// `--generate-completion-script` flag is not something anybody guesses.
struct CompletionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: "Print a shell completion script.",
        discussion: """
            The script goes to stdout, so redirect or source it:

              # zsh — somewhere on your $fpath
              issues completion zsh > ~/.zfunc/_issues

              # bash
              issues completion bash > ~/.local/share/bash-completion/completions/issues

              # fish
              issues completion fish > ~/.config/fish/completions/issues.fish

            Or, to try it in the current shell only: source <(issues completion zsh)

            Completions are generated locally from the commands themselves, so this \
            needs no server and no credential.
            """)

    @Argument(
        help: "Which shell: \(CompletionCommand.supported).",
        completion: .list(CompletionShell.allCases.map(\.rawValue)))
    var shell: String

    static var supported: String {
        CompletionShell.allCases.map(\.rawValue).joined(separator: ", ")
    }

    func run() async throws {
        guard let parsed = CompletionShell(rawValue: shell) else {
            throw ValidationError(
                "'\(shell)' is not a supported shell. Supported: \(Self.supported).")
        }
        // Deliberately nothing else on stdout: the output is meant to be redirected
        // into a file or sourced, and a friendly note would corrupt it.
        Runtime.require().terminal.print(Root.completionScript(for: parsed))
    }
}
