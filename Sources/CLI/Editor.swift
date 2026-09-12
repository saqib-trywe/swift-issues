import Foundation

/// Composing Markdown in `$EDITOR`, git-style.
///
/// The conventions are git's on purpose — `#` lines are instructions, an empty
/// buffer aborts — because that is the muscle memory anybody reaching for this
/// already has.
enum Editor {

    /// The line below which nothing is kept.
    ///
    /// git's "scissors" convention. It exists because `# Heading` is both valid
    /// Markdown and a plausible instruction, so no rule about `#` can tell them
    /// apart — and guessing wrong deletes what somebody wrote. A positional marker
    /// cannot be ambiguous.
    static let scissors = "# ------------------------ >8 ------------------------"

    /// What the buffer starts as: the current text, then the scissors, then
    /// instructions below it.
    static func template(current: String, instructions: [String]) -> String {
        let comments = instructions.map { "# \($0)" }.joined(separator: "\n")
        return """
            \(current)

            \(scissors)
            # Everything below this line is ignored. An empty message aborts.
            \(comments)
            """
    }

    /// What the user actually wrote: everything above the scissors.
    ///
    /// Returns `nil` when nothing is left, which is how an edit is cancelled.
    /// If the scissors line is gone the whole buffer is kept — losing text because
    /// a marker was deleted would be the worst possible failure here.
    static func content(of raw: String) -> String? {
        let body = raw.range(of: scissors).map { String(raw[raw.startIndex..<$0.lowerBound]) } ?? raw
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `$VISUAL`, then `$EDITOR`, then `vi` — the long-standing order.
    static func command(environment: [String: String]) -> String {
        if let visual = environment["VISUAL"], !visual.isEmpty { return visual }
        if let editor = environment["EDITOR"], !editor.isEmpty { return editor }
        return "vi"
    }

    /// Runs the editor over a temporary file and returns what came back.
    ///
    /// The production path. Never reached in tests: the launcher is a closure on
    /// `CommandContext`, so nothing here spawns a process during a test run.
    static func run(template: String, environment: [String: String]) throws -> String? {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ISSUES_EDITMSG-\(UUID().uuidString).md")
        try Data(template.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        // Through a shell, because $EDITOR routinely carries arguments
        // ("code -w", "subl -n -w") and splitting it here would get quoting wrong.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command(environment: environment)) \"$1\"", "sh", file.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.malformedConfiguration(
                "The editor exited with status \(process.terminationStatus); nothing was changed.")
        }
        return content(of: try String(contentsOf: file, encoding: .utf8))
    }
}
