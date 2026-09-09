import Core
import Foundation
import Testing

@Suite("Validation: title")
struct TitleValidationTests {

    @Test("accepts an ordinary title")
    func acceptsOrdinaryTitle() {
        #expect(Validation.title("Sync queue stalls behind a quarantined op").isEmpty)
    }

    /// Title is the only field a human must supply, so "required" has to mean
    /// something stronger than "the key was present".
    @Test("rejects a title that is empty or only whitespace", arguments: ["", "   ", "\t\n "])
    func rejectsBlankTitle(raw: String) {
        let failures = Validation.title(raw)

        #expect(failures.count == 1)
        #expect(failures.first?.field == "title")
        #expect(failures.first?.code == .required)
    }

    @Test("accepts 512 characters and rejects 513")
    func enforcesLengthLimit() {
        #expect(Validation.title(String(repeating: "a", count: 512)).isEmpty)

        let failures = Validation.title(String(repeating: "a", count: 513))
        #expect(failures.map(\.code) == [.tooLong])
    }

    /// A title that is only whitespace once trimmed is blank, not long, so the
    /// two rules must not both fire and produce a confusing pair of errors.
    @Test("reports blank rather than both blank and too long")
    func blankTakesPrecedenceOverLength() {
        let failures = Validation.title(String(repeating: " ", count: 600))

        #expect(failures.map(\.code) == [.required])
    }
}

@Suite("Validation: long-form text")
struct TextValidationTests {

    @Test("a description may be empty — it is optional on creation")
    func descriptionMayBeEmpty() {
        #expect(Validation.description("").isEmpty)
    }

    @Test("a comment body may not be empty")
    func commentBodyMayNotBeEmpty() {
        let failures = Validation.commentBody("   ")

        #expect(failures.map(\.code) == [.required])
        #expect(failures.first?.field == "body")
    }

    @Test("accepts text at the byte limit and rejects text over it")
    func enforcesByteLimit() {
        let atLimit = String(repeating: "a", count: Validation.maxTextBytes)
        #expect(Validation.description(atLimit).isEmpty)

        let overLimit = String(repeating: "a", count: Validation.maxTextBytes + 1)
        #expect(Validation.description(overLimit).map(\.code) == [.tooLarge])
    }

    /// The limit is UTF-8 bytes, not characters. This string is far under the
    /// limit by `count` and far over it by bytes — a character-based check would
    /// pass it and the server would then reject it, manufacturing exactly the
    /// client-passes/server-fails split quarantine exists to absorb.
    @Test("counts UTF-8 bytes rather than characters")
    func countsBytesNotCharacters() {
        let emoji = "\u{1F926}\u{1F3FD}\u{200D}\u{2640}\u{FE0F}"  // one grapheme, 17 bytes
        let text = String(repeating: emoji, count: 5000)

        #expect(text.count < Validation.maxTextBytes)
        #expect(text.utf8.count > Validation.maxTextBytes)
        #expect(Validation.description(text).map(\.code) == [.tooLarge])
    }
}

@Suite("Validation: accumulation")
struct AccumulationTests {

    /// Fail-fast would make a form reveal one problem per submit. Ticket 06's
    /// error payload is an array precisely because it expects several.
    @Test("reports every failing field at once, not just the first")
    func reportsEveryFailingField() {
        let failures = Validation.issue(
            title: "   ",
            description: String(repeating: "a", count: Validation.maxTextBytes + 1)
        )

        #expect(failures.count == 2)
        #expect(failures.map(\.field) == ["title", "description"])
        #expect(failures.map(\.code) == [.required, .tooLarge])
    }

    @Test("a valid issue produces no failures")
    func validIssueProducesNoFailures() {
        #expect(Validation.issue(title: "Add a partial index", description: "").isEmpty)
    }

    @Test("field order is stable, so error lists do not shuffle between runs")
    func fieldOrderIsStable() {
        let input = (title: "", description: String(repeating: "a", count: Validation.maxTextBytes + 1))
        let first = Validation.issue(title: input.title, description: input.description)
        let second = Validation.issue(title: input.title, description: input.description)

        #expect(first == second)
    }
}

@Suite("ValidationFailure wire shape")
struct ValidationFailureWireTests {

    @Test("a comment is validated through its own entry point")
    func commentEntryPoint() {
        #expect(Validation.comment(body: "Looks right to me.").isEmpty)
        #expect(Validation.comment(body: "").map(\.code) == [.required])
    }

    /// Ticket 06: `errors: [{field, code, message}]`. The code is the stable part
    /// clients branch on, so it must appear verbatim on the wire rather than as
    /// an integer or a localised string.
    @Test("encodes as field, code and message, with a stable code string")
    func encodesAsTicket06Shape() throws {
        let failure = ValidationFailure(
            field: "title", code: .required, message: "A title is required.")

        let data = try JSONCoders.encoder.encode(failure)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["field"] as? String == "title")
        #expect(object["code"] as? String == "required")
        #expect(object["message"] as? String == "A title is required.")
    }

    @Test(
        "every code has a stable wire spelling",
        arguments: [
            (ValidationCode.required, "required"),
            (ValidationCode.tooLong, "tooLong"),
            (ValidationCode.tooLarge, "tooLarge"),
        ]
    )
    func codesHaveStableSpellings(code: ValidationCode, wire: String) {
        #expect(code.rawValue == wire)
    }
}
