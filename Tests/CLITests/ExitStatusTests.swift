import Core
import Testing

@testable import CLI

/// Ticket 11 fixes the exit codes because they are the CLI's script-facing
/// contract: 0 success, 1 generic failure, 2 usage, 3 not found, 4 auth,
/// 5 conflict, 6 gone. Getting 3 and 6 apart is the whole reason the API bothers
/// to distinguish 404 from 410.
@Suite("Exit codes")
struct ExitCodeTests {

    @Test(
        "an API failure maps to its documented code",
        arguments: [
            (APIError.notFound(nil), Int32(3)),
            (APIError.gone(nil), Int32(6)),
            (APIError.unauthenticated(nil), Int32(4)),
            (APIError.forbidden(nil), Int32(4)),
            (APIError.conflict(nil), Int32(5)),
            (APIError.invalidRequest(nil), Int32(2)),
            (APIError.rateLimited(retryAfter: 60, problem: nil), Int32(1)),
            (APIError.server(status: 503, problem: nil), Int32(1)),
            (APIError.unexpectedStatus(418), Int32(1)),
        ])
    func apiFailureMapsToItsDocumentedCode(error: APIError, expected: Int32) {
        #expect(ExitStatus.forError(error) == expected)
    }

    /// A deleted issue and a nonexistent one are different script branches, which
    /// is the point of the 410 the server goes out of its way to return.
    @Test("gone and not found do not collapse")
    func goneAndNotFoundDoNotCollapse() {
        #expect(ExitStatus.forError(APIError.gone(nil)) != ExitStatus.forError(APIError.notFound(nil)))
    }

    /// Holding no token is an auth failure the same as a rejected one: in both
    /// cases the fix is `issues auth login`.
    @Test("a missing token is an auth failure")
    func missingTokenIsAnAuthFailure() {
        #expect(ExitStatus.forError(CLIError.notAuthenticated(server: "https://x")) == 4)
    }

    /// No server configured is something the user must supply, so it is a usage
    /// failure rather than a generic one.
    @Test("a missing server is a usage failure")
    func missingServerIsAUsageFailure() {
        #expect(ExitStatus.forError(CLIError.noServerConfigured) == 2)
    }

    @Test("an unrecognised error is a generic failure")
    func unrecognisedErrorIsAGenericFailure() {
        struct Surprise: Error {}
        #expect(ExitStatus.forError(Surprise()) == 1)
    }
}
