import Core
import Credentials
import Foundation

/// Handles one MCP conversation.
///
/// Pure request-in/response-out, so the protocol is testable without a process.
/// The stdio loop below is the only part that touches the outside world.
public struct MCPSession: Sendable {
    /// The specification revision this implements.
    public static let protocolVersion = "2025-06-18"

    private let runner: ToolRunner?
    /// Why there is no runner, when there is none.
    private let configurationFailure: String?

    public init(runner: ToolRunner) {
        self.runner = runner
        self.configurationFailure = nil
    }

    /// An unconfigured session still speaks the protocol.
    ///
    /// A server that exits because `ISSUES_URL` is unset gives the host nothing to
    /// show: the tools appear, and calling one explains what to set. That is far
    /// easier to act on than a process that dies at startup.
    public init(configurationFailure: String) {
        self.runner = nil
        self.configurationFailure = configurationFailure
    }

    /// Answers one message, or returns `nil` for a notification.
    public func handle(_ line: String) async -> String? {
        let request: RPCRequest
        do {
            request = try JSONRPC.parse(line)
        } catch let error as RPCError {
            return JSONRPC.failure(id: nil, error: error)
        } catch {
            return JSONRPC.failure(id: nil, error: .internalError(String(describing: error)))
        }

        do {
            let result = try await respond(to: request)
            // A notification expects no reply; answering one confuses a client's
            // pending table.
            guard let id = request.id else { return nil }
            return JSONRPC.response(id: id, result: result)
        } catch let error as RPCError {
            guard request.id != nil else { return nil }
            return JSONRPC.failure(id: request.id, error: error)
        } catch {
            guard request.id != nil else { return nil }
            return JSONRPC.failure(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func respond(to request: RPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            return .object([
                "protocolVersion": .string(Self.protocolVersion),
                // Only tools: no resources, no prompts, nothing this does not do.
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("issues"),
                    "version": .string("0.1.0"),
                ]),
            ])

        case "notifications/initialized", "notifications/cancelled":
            return .null

        case "ping":
            return .object([:])

        case "tools/list":
            return .object(["tools": .array(Tools.all.map(\.listing))])

        case "tools/call":
            return await callTool(request.params)

        default:
            throw RPCError.methodNotFound(request.method)
        }
    }

    /// Runs a tool, reporting failure *inside* the result rather than as a protocol
    /// error.
    ///
    /// MCP draws that distinction deliberately: a protocol error means the call was
    /// malformed, while a tool that ran and failed is something the model should see
    /// and can act on. Returning -32603 for "title must not be empty" hides it from
    /// the model entirely.
    private func callTool(_ params: JSONValue) async -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            return Self.text("The call is missing a tool name.", isError: true)
        }
        guard Tools.named(name) != nil else {
            return Self.text(
                "There is no tool called '\(name)'. Available: "
                    + Tools.all.map(\.name).joined(separator: ", ") + ".",
                isError: true)
        }
        guard let runner else {
            return Self.text(configurationFailure ?? "This server is not configured.", isError: true)
        }

        do {
            return Self.text(
                try await runner.call(name, arguments: params["arguments"] ?? .object([:])))
        } catch let failure as ToolFailure {
            return Self.text(failure.description, isError: true)
        } catch let error as APIError {
            return Self.text(Self.describe(error), isError: true)
        } catch {
            return Self.text(String(describing: error), isError: true)
        }
    }

    static func text(_ body: String, isError: Bool = false) -> JSONValue {
        var result: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(body)])])
        ]
        if isError { result["isError"] = .bool(true) }
        return .object(result)
    }

    /// Renders a failure as something an agent can act on.
    ///
    /// Ticket 12: the problem's title, detail and field errors as plain text —
    /// "title must not be empty", not a bare status code.
    static func describe(_ error: APIError) -> String {
        switch error {
        case .rateLimited(let retryAfter, _):
            let seconds = max(1, retryAfter.map { Int($0) } ?? 60)
            return
                "Rate limited. Wait \(seconds) second\(seconds == 1 ? "" : "s") before trying "
                + "again, and do not retry sooner."
        case .invalidRequest(let problem):
            let fields = (problem?.errors ?? []).map { "\($0.field): \($0.message)" }
            let detail = problem?.detail ?? "The request was rejected."
            return fields.isEmpty ? detail : detail + "\n" + fields.joined(separator: "\n")
        case .forbidden(let problem):
            return problem?.detail
                ?? "This agent token is not permitted to do that. Agent tokens cannot "
                + "manage users, delete anything, or administer the instance."
        case .unauthenticated:
            return "The token is not valid. Check ISSUES_TOKEN."
        case .notFound(let problem):
            return problem?.detail ?? "Not found."
        case .gone(let problem):
            return problem?.detail ?? "That was deleted."
        case .conflict(let problem):
            return problem?.detail ?? "That conflicts with something that already exists."
        case .server(let status, let problem):
            return problem?.detail ?? "The server failed (HTTP \(status))."
        case .unexpectedStatus(let status):
            return "Unexpected response from the server (HTTP \(status))."
        }
    }
}
