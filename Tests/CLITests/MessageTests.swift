import Core
import Foundation
import Testing

@testable import CLI

/// What a failure actually reads like. These are the strings a person sees when
/// something has gone wrong, which makes them worth asserting rather than
/// assuming.
@Suite("Error messages")
struct MessageTests {

    private func problem(_ detail: String, status: Int) -> Problem {
        Problem(type: "about:blank", title: "Failed", status: status, detail: detail)
    }

    /// The server writes `detail` for this exact situation; a status name is not
    /// written for anybody.
    @Test("the server's detail is preferred when there is one")
    func serversDetailIsPreferred() {
        let message = IssuesCLI.message(
            for: APIError.notFound(problem("No issue with key PROJ-9999.", status: 404)))
        #expect(message == "No issue with key PROJ-9999.")
    }

    @Test(
        "there is a fallback when the server sends no detail",
        arguments: [
            APIError.notFound(nil),
            APIError.forbidden(nil),
            APIError.conflict(nil),
            APIError.invalidRequest(nil),
            APIError.unauthenticated(nil),
            APIError.server(status: 503, problem: nil),
            APIError.unexpectedStatus(418),
        ])
    func fallbackWhenNoDetail(_ error: APIError) {
        let message = IssuesCLI.message(for: error)
        #expect(!message.isEmpty)
        #expect(!message.contains("nil"))
    }

    /// The distinct copy is the only place ticket 06's decision to return 410
    /// rather than 404 reaches a human.
    @Test("gone and not found read differently")
    func goneAndNotFoundReadDifferently() {
        let gone = IssuesCLI.message(for: APIError.gone(nil))
        let missing = IssuesCLI.message(for: APIError.notFound(nil))

        #expect(gone != missing)
        #expect(gone.lowercased().contains("deleted"))
    }

    @Test("a 401 says how to fix it")
    func unauthenticatedSaysHowToFixIt() {
        #expect(IssuesCLI.message(for: APIError.unauthenticated(nil)).contains("auth login"))
    }

    /// Field failures are the useful part of a 422 and must not be swallowed.
    @Test("validation failures are listed")
    func validationFailuresAreListed() {
        let failures = [
            ValidationFailure(
                field: "title", code: .tooLong, message: "A title may be at most 512 characters."),
            ValidationFailure(field: "dueDate", code: .invalid, message: "Not a calendar date."),
        ]
        let message = IssuesCLI.message(
            for: APIError.invalidRequest(
                Problem(
                    type: "about:blank", title: "Invalid", status: 422, detail: "Rejected.", errors: failures)
            ))

        #expect(message.contains("title"))
        #expect(message.contains("at most 512"))
        #expect(message.contains("dueDate"))
    }

    @Test("a 422 with no field failures still says something")
    func validationWithNoFieldFailuresStillSaysSomething() {
        let message = IssuesCLI.message(
            for: APIError.invalidRequest(
                Problem(type: "about:blank", title: "Invalid", status: 422, detail: "Rejected.", errors: [])))
        #expect(message == "Rejected.")
    }

    /// Ticket 11 asks for this exact shape. "Try again in 840 seconds" is a number
    /// somebody has to do arithmetic on while already locked out.
    @Test("a lockout is reported in minutes")
    func lockoutIsReportedInMinutes() {
        let message = IssuesCLI.message(
            for: APIError.rateLimited(retryAfter: 720, problem: nil))
        #expect(message == "Too many failed attempts — try again in 12 minutes.")
    }

    @Test("a lockout without a Retry-After still says what happened")
    func lockoutWithoutRetryAfter() {
        let message = IssuesCLI.message(for: APIError.rateLimited(retryAfter: nil, problem: nil))
        #expect(message.contains("Too many failed attempts"))
    }

    @Test(
        "durations read naturally",
        arguments: [
            (TimeInterval(1), "1 second"),
            (TimeInterval(45), "45 seconds"),
            (TimeInterval(60), "1 minute"),
            (TimeInterval(61), "2 minutes"),
            (TimeInterval(900), "15 minutes"),
        ])
    func durationsReadNaturally(seconds: TimeInterval, expected: String) {
        #expect(IssuesCLI.humanDuration(seconds) == expected)
    }

    @Test("an unrecognised error still produces something")
    func unrecognisedErrorStillProducesSomething() {
        struct Surprise: Error {}
        #expect(!IssuesCLI.message(for: Surprise()).isEmpty)
    }

    @Test(
        "a CLI error describes itself",
        arguments: [
            CLIError.noServerConfigured,
            CLIError.notAuthenticated(server: "https://x.test"),
            CLIError.missingInput(flag: "--email"),
            CLIError.editorUnavailable,
            CLIError.cancelled,
            CLIError.malformedConfiguration("bad"),
        ])
    func cliErrorDescribesItself(_ error: CLIError) {
        #expect(!IssuesCLI.message(for: error).isEmpty)
    }
}
