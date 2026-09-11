import Core
import Foundation

/// The CLI's script-facing contract.
///
/// Ticket 11 fixes these numbers: 0 success, 1 generic failure, 2 usage error,
/// 3 not found, 4 auth failure, 5 conflict, 6 gone. They are a published
/// interface — a script branching on 6 to mean "deleted" breaks if these move.
enum ExitStatus {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let notFound: Int32 = 3
    static let authentication: Int32 = 4
    static let conflict: Int32 = 5
    static let gone: Int32 = 6

    static func forError(_ error: any Error) -> Int32 {
        switch error {
        case let error as APIError: forAPIError(error)
        case let error as CLIError: forCLIError(error)
        default: failure
        }
    }

    private static func forAPIError(_ error: APIError) -> Int32 {
        switch error {
        case .notFound: notFound
        case .gone: gone
        // `forbidden` shares a code with `unauthenticated` because ticket 11
        // allocates no separate permission code. The messages differ, so a human
        // can still tell "log in again" from "you may not do that"; a script
        // cannot, which is a known limit of the fixed code list.
        case .unauthenticated, .forbidden: authentication
        case .conflict: conflict
        // A rejected field value is the caller having invoked the command wrongly,
        // which is what exit 2 means to a script, even though the rejection
        // arrived from the server rather than the parser.
        case .invalidRequest: usage
        case .rateLimited, .server, .unexpectedStatus: failure
        }
    }

    private static func forCLIError(_ error: CLIError) -> Int32 {
        switch error {
        case .notAuthenticated: authentication
        case .noServerConfigured, .missingInput: usage
        case .editorUnavailable, .cancelled, .malformedConfiguration: failure
        }
    }
}

/// A failure originating in the CLI rather than in a response.
enum CLIError: Error, Equatable {
    /// No server URL in the environment, the config file, or a flag.
    case noServerConfigured
    /// No credential for this server. Distinct from a rejected one only in the
    /// message, since the remedy is the same.
    case notAuthenticated(server: String)
    /// A required value was not supplied and could not be prompted for, because
    /// stdin is not a terminal. Naming the flag is the whole point: a CI job that
    /// blocks on an invisible prompt looks like a hang, not a mistake.
    case missingInput(flag: String)
    /// `$EDITOR` is unset and there is no terminal to fall back to.
    case editorUnavailable
    /// The user declined a destructive confirmation.
    case cancelled
    case malformedConfiguration(String)
}

extension CLIError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noServerConfigured:
            "No server configured. Set one with `issues config set url <URL>`, or set ISSUES_URL."
        case .notAuthenticated(let server):
            "Not logged in to \(server). Run `issues auth login`."
        case .missingInput(let flag):
            "Missing required value: pass \(flag). (Nothing was prompted for, because stdin is not a terminal.)"
        case .editorUnavailable:
            "No $EDITOR set and stdin is not a terminal. Pass the text with a flag, or `-` to read stdin."
        case .cancelled:
            "Cancelled."
        case .malformedConfiguration(let detail):
            detail
        }
    }
}
