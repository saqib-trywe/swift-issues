import Foundation
import Testing

@testable import CLI

/// The editor follows git's conventions because that is the muscle memory people
/// already have: everything below the scissors line is ignored, and saving
/// nothing aborts.
@Suite("Editor content")
struct EditorTests {

    @Test("everything below the scissors is stripped")
    func everythingBelowTheScissorsIsStripped() {
        let raw = """
            The actual description.

            \(Editor.scissors)
            # Everything below this line is ignored.
            # Write a description above.
            """
        #expect(Editor.content(of: raw) == "The actual description.")
    }

    /// A Markdown heading starts with '#' too, so any rule about '#' would delete
    /// the user's own text. The scissors are positional and cannot be ambiguous.
    @Test("markdown headings above the scissors survive")
    func markdownHeadingsSurvive() {
        let raw = """
            # Heading

            Body with a ## subheading.

            \(Editor.scissors)
            # Write a description above.
            """
        let content = try! #require(Editor.content(of: raw))
        #expect(content.hasPrefix("# Heading"))
        #expect(content.contains("## subheading"))
    }

    /// Losing somebody's text because a marker was deleted would be the worst
    /// failure available here, so the whole buffer is kept instead.
    @Test("a deleted scissors line keeps everything")
    func deletedScissorsKeepsEverything() {
        #expect(Editor.content(of: "# Heading\n\nBody.") == "# Heading\n\nBody.")
    }

    @Test("saving nothing aborts")
    func savingNothingAborts() {
        #expect(Editor.content(of: "") == nil)
        #expect(Editor.content(of: "   \n\n  ") == nil)
        #expect(Editor.content(of: Editor.template(current: "", instructions: ["Write a thing."])) == nil)
    }

    @Test("surrounding blank lines are trimmed")
    func surroundingBlankLinesAreTrimmed() {
        #expect(Editor.content(of: "\n\n  Text.  \n\n") == "Text.")
    }

    /// Interior blank lines are paragraph breaks in Markdown and must survive.
    @Test("interior blank lines survive")
    func interiorBlankLinesSurvive() {
        #expect(Editor.content(of: "One.\n\nTwo.") == "One.\n\nTwo.")
    }

    @Test("the template carries the current text above the instructions")
    func templateCarriesCurrentText() {
        let template = Editor.template(current: "Existing text.", instructions: ["Write a thing."])

        #expect(template.hasPrefix("Existing text."))
        #expect(template.contains("# Write a thing."))
        // Round-trips: opening and saving unchanged must not alter the text.
        #expect(Editor.content(of: template) == "Existing text.")
    }

    @Test("an empty current text still produces usable instructions")
    func emptyCurrentTextStillProducesInstructions() {
        let template = Editor.template(current: "", instructions: ["Write a thing."])

        #expect(template.contains("# Write a thing."))
        #expect(Editor.content(of: template) == nil)
    }

    /// VISUAL wins over EDITOR by long convention; neither set on a terminal falls
    /// back to vi, as git does.
    @Test(
        "the editor command is chosen by convention",
        arguments: [
            (["VISUAL": "code -w", "EDITOR": "vim"], "code -w"),
            (["EDITOR": "vim"], "vim"),
            ([String: String](), "vi"),
        ])
    func editorCommandIsChosenByConvention(environment: [String: String], expected: String) {
        #expect(Editor.command(environment: environment) == expected)
    }
}

/// The one production path the command tests deliberately avoid.
///
/// Commands take the launcher as a closure so no command test spawns a process.
/// That leaves `Editor.run` itself uncovered, and it is where the quoting, the
/// temp file and the exit-status handling live — so it gets its own tests, with a
/// scripted `$EDITOR` rather than a real one.
@Suite("Editor subprocess")
struct EditorSubprocessTests {

    /// Writes a shell script that acts as an editor, and returns its path.
    private func scriptedEditor(_ body: String) throws -> (command: String, cleanup: () -> Void) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fake-editor-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (url.path, { try? FileManager.default.removeItem(at: url) })
    }

    @Test("what the editor writes comes back")
    func whatTheEditorWritesComesBack() throws {
        let editor = try scriptedEditor(#"printf 'Written by the editor.\n' > "$1""#)
        defer { editor.cleanup() }

        let result = try Editor.run(
            template: Editor.template(current: "", instructions: ["Write something."]),
            environment: ["EDITOR": editor.command])

        #expect(result == "Written by the editor.")
    }

    /// The template has to reach the editor, or an edit would silently start from
    /// an empty buffer and replace the existing text with whatever was typed.
    @Test("the editor receives the template")
    func editorReceivesTheTemplate() throws {
        // Keeps only the first line of what it was given, proving it read the file.
        let editor = try scriptedEditor(#"head -1 "$1" > "$1.tmp" && mv "$1.tmp" "$1""#)
        defer { editor.cleanup() }

        let result = try Editor.run(
            template: Editor.template(current: "Existing text.", instructions: ["Edit it."]),
            environment: ["EDITOR": editor.command])

        #expect(result == "Existing text.")
    }

    @Test("an editor that saves nothing aborts")
    func editorThatSavesNothingAborts() throws {
        let editor = try scriptedEditor(#": > "$1""#)
        defer { editor.cleanup() }

        let result = try Editor.run(
            template: Editor.template(current: "Existing.", instructions: ["Edit it."]),
            environment: ["EDITOR": editor.command])

        #expect(result == nil)
    }

    /// `$EDITOR` routinely carries arguments — "code -w", "subl -n -w" — so it goes
    /// through a shell rather than being split here, where the quoting would be
    /// wrong for anything unusual.
    @Test("an editor command with arguments works")
    func editorCommandWithArgumentsWorks() throws {
        let editor = try scriptedEditor(#"printf 'Flag was %s.\n' "$1" > "$2""#)
        defer { editor.cleanup() }

        let result = try Editor.run(
            template: "ignored",
            environment: ["EDITOR": "\(editor.command) --wait"])

        #expect(result == "Flag was --wait.")
    }

    /// A path with a space must not be re-split by the shell, or the editor is
    /// handed two nonexistent files and the edit is silently lost.
    @Test("a temporary path is passed as one argument")
    func temporaryPathIsPassedAsOneArgument() throws {
        let editor = try scriptedEditor(#"printf 'Got %s args.\n' "$#" > "$1""#)
        defer { editor.cleanup() }

        let result = try Editor.run(
            template: "ignored", environment: ["EDITOR": editor.command])

        #expect(result == "Got 1 args.")
    }

    /// A non-zero exit means the editor failed or was killed. Treating that as "the
    /// user saved an empty buffer" would quietly discard their text.
    @Test("a failing editor is an error, not an abandoned edit")
    func failingEditorIsAnError() throws {
        let editor = try scriptedEditor("exit 3")
        defer { editor.cleanup() }

        #expect(throws: CLIError.self) {
            try Editor.run(template: "ignored", environment: ["EDITOR": editor.command])
        }
    }

    /// The temp file must not survive: it holds issue text, and a stray copy in
    /// /tmp is readable by every account on the machine.
    @Test("the temporary file is removed afterwards")
    func temporaryFileIsRemovedAfterwards() throws {
        let editor = try scriptedEditor(
            #"printf '%s\n' "$1" > /tmp/issues-editor-path.txt; printf 'x\n' > "$1""#)
        defer {
            editor.cleanup()
            try? FileManager.default.removeItem(atPath: "/tmp/issues-editor-path.txt")
        }

        _ = try Editor.run(template: "ignored", environment: ["EDITOR": editor.command])

        let recorded = try String(contentsOfFile: "/tmp/issues-editor-path.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!recorded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: recorded))
    }
}
