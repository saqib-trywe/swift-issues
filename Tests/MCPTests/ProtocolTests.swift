import Core
import Credentials
import Foundation
import Testing

@testable import MCP

/// The JSON-RPC layer. Hand-rolled, so its conformance to the specification is
/// what these assert.
@Suite("JSON-RPC")
struct JSONRPCTests {

    @Test("a well-formed request parses")
    func wellFormedRequestParses() throws {
        let request = try JSONRPC.parse(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)

        #expect(request.method == "tools/list")
        #expect(request.id == .number(1))
        #expect(!request.isNotification)
    }

    /// A request with no id is a notification. Answering one is a protocol
    /// violation that confuses a client's pending table.
    @Test("a request with no id is a notification")
    func requestWithNoIdIsANotification() throws {
        let request = try JSONRPC.parse(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(request.isNotification)
    }

    /// An explicit null id is a notification too, by the same reasoning.
    @Test("an explicitly null id is a notification")
    func explicitlyNullIdIsANotification() throws {
        #expect(try JSONRPC.parse(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#).isNotification)
    }

    /// String ids are legal and common; treating them as invalid would break real
    /// clients.
    @Test("a string id is preserved")
    func stringIdIsPreserved() throws {
        let request = try JSONRPC.parse(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        #expect(request.id == .string("abc"))
    }

    @Test("malformed input is a parse error", arguments: ["", "not json", "{", "[1,2"])
    func malformedInputIsAParseError(_ line: String) {
        #expect(throws: RPCError.self) { try JSONRPC.parse(line) }
    }

    @Test(
        "a missing version or method is an invalid request",
        arguments: [
            #"{"id":1,"method":"ping"}"#,
            #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1}"#,
        ])
    func missingVersionOrMethodIsInvalid(_ line: String) {
        #expect(throws: RPCError.self) { try JSONRPC.parse(line) }
    }

    /// stdio framing is one message per line, so a newline inside a reply would
    /// split it in two.
    @Test("a response is a single line")
    func responseIsASingleLine() {
        let rendered = JSONRPC.response(
            id: .number(1), result: .object(["text": .string("one\ntwo")]))

        #expect(!rendered.contains("\n"))
        #expect(rendered.contains(#"\n"#), "the newline should be escaped, not dropped")
    }

    @Test("an error response carries the code and message")
    func errorResponseCarriesCodeAndMessage() throws {
        let rendered = JSONRPC.failure(id: .number(2), error: .methodNotFound("nope"))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(rendered.utf8))

        #expect(value["error"]?["code"]?.intValue == -32_601)
        #expect(value["error"]?["message"]?.stringValue?.contains("nope") == true)
    }

    /// Whole numbers written as floats are needless noise, and some clients are
    /// fussy about it.
    @Test("whole numbers encode as integers")
    func wholeNumbersEncodeAsIntegers() {
        let rendered = JSONRPC.response(id: .number(1), result: .object(["limit": .number(25)]))
        #expect(rendered.contains("\"limit\":25"))
        #expect(!rendered.contains("25.0"))
    }
}

@Suite("MCP session")
struct MCPSessionTests {

    private let session = MCPSession(configurationFailure: "no server configured")

    private func result(_ line: String) async throws -> JSONValue {
        let reply = try #require(await session.handle(line))
        return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
    }

    @Test("initialize reports the protocol version and the tools capability")
    func initializeReportsVersionAndCapability() async throws {
        let value = try await result(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)

        #expect(value["result"]?["protocolVersion"]?.stringValue == MCPSession.protocolVersion)
        #expect(value["result"]?["capabilities"]?["tools"] != nil)
        #expect(value["result"]?["serverInfo"]?["name"]?.stringValue == "issues")
    }

    /// Declaring only what it does: no resources, no prompts.
    @Test("no capability is claimed that is not implemented")
    func noUnimplementedCapabilityIsClaimed() async throws {
        let value = try await result(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let capabilities = try #require(value["result"]?["capabilities"])

        #expect(capabilities["resources"] == nil)
        #expect(capabilities["prompts"] == nil)
    }

    @Test("a notification gets no reply")
    func notificationGetsNoReply() async {
        #expect(await session.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test("ping is answered")
    func pingIsAnswered() async throws {
        let value = try await result(#"{"jsonrpc":"2.0","id":7,"method":"ping","params":{}}"#)
        #expect(value["id"]?.intValue == 7)
        #expect(value["error"] == nil)
    }

    @Test("an unknown method is a method-not-found error")
    func unknownMethodIsMethodNotFound() async throws {
        let value = try await result(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        #expect(value["error"]?["code"]?.intValue == -32_601)
    }

    @Test("tools/list returns every tool with a schema")
    func toolsListReturnsEveryTool() async throws {
        let value = try await result(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try #require(value["result"]?["tools"]?.arrayValue)

        #expect(tools.count == Tools.all.count)
        for tool in tools {
            #expect(tool["name"]?.stringValue?.isEmpty == false)
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
        }
    }

    /// Malformed input is a protocol error; a tool that ran and failed is something
    /// the model should see. Conflating them hides the failure from the model.
    @Test("a tool failure is reported in the result, not as a protocol error")
    func toolFailureIsReportedInTheResult() async throws {
        let value = try await result(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami"}}"#)

        #expect(value["error"] == nil, "a tool failure became a protocol error")
        #expect(value["result"]?["isError"]?.boolValue == true)
    }

    /// A server that exits because ISSUES_URL is unset gives the host nothing to
    /// show. This tells the agent exactly what to set.
    @Test("an unconfigured server still lists tools and explains itself")
    func unconfiguredServerStillListsToolsAndExplains() async throws {
        let listed = try await result(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(listed["result"]?["tools"]?.arrayValue?.isEmpty == false)

        let called = try await result(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_issues"}}"#)
        let text = try #require(called["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.contains("no server configured"))
    }

    @Test("calling a tool that does not exist names the ones that do")
    func callingAMissingToolNamesTheRealOnes() async throws {
        let value = try await result(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_everything"}}"#)
        let text = try #require(value["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)

        #expect(value["result"]?["isError"]?.boolValue == true)
        #expect(text.contains("list_issues"))
    }
}

@Suite("Tool surface")
struct ToolSurfaceTests {

    /// Ticket 12 fixes the list, and each exists for a reason.
    @Test("the ten specified tools are present")
    func theTenSpecifiedToolsArePresent() {
        let expected = [
            "list_issues", "get_issue", "create_issue", "update_issue", "add_comment",
            "list_comments", "list_projects", "list_labels", "list_users", "whoami",
        ]
        #expect(Tools.all.map(\.name).sorted() == expected.sorted())
    }

    /// No destructive tools in v1. Deletion is a tombstone nobody can undo, and an
    /// agent looping on a misparsed instruction is precisely the actor not to hand
    /// that to.
    @Test("nothing destructive is exposed")
    func nothingDestructiveIsExposed() {
        for name in Tools.all.map(\.name) {
            #expect(!name.contains("delete"))
            #expect(!name.contains("archive"))
            #expect(!name.contains("deactivate"))
        }
    }

    /// An agent that retries through a 429 is the failure the limit exists to stop,
    /// so every tool has to say so.
    @Test("every tool tells the agent to honour Retry-After")
    func everyToolTellsTheAgentToHonourRetryAfter() {
        for tool in Tools.all {
            #expect(
                tool.description.contains("429") && tool.description.contains("wait"),
                "\(tool.name) does not mention the rate limit")
        }
    }

    /// The reason the list tools deviate from the raw-payload rule: fifty issues
    /// with full Markdown can consume an agent's context in one call.
    @Test("list_issues says it omits the description and points at get_issue")
    func listIssuesExplainsItsProjection() {
        let tool = Tools.named("list_issues")!
        #expect(tool.description.contains("omits the description"))
        #expect(tool.description.contains("get_issue"))
    }

    /// An agent should learn its own limits from the tool rather than from a 403.
    @Test("whoami states what an agent token cannot do")
    func whoamiStatesWhatAnAgentCannotDo() {
        let description = Tools.named("whoami")!.description
        #expect(description.contains("cannot"))
        #expect(description.contains("delete"))
    }

    /// update_issue is an agent's way to make something go away, and it must say so
    /// since there is no delete.
    @Test("update_issue explains cancellation in place of deletion")
    func updateIssueExplainsCancellation() {
        let description = Tools.named("update_issue")!.description
        #expect(description.contains("cancelled"))
        #expect(description.contains("no way to delete"))
    }

    @Test(
        "required arguments are declared",
        arguments: [
            ("get_issue", "issue"), ("create_issue", "title"), ("update_issue", "issue"),
            ("add_comment", "body"), ("list_labels", "project"),
        ])
    func requiredArgumentsAreDeclared(tool: String, argument: String) throws {
        let schema = try #require(Tools.named(tool)).inputSchema
        let required = try #require(schema["required"]?.arrayValue).compactMap(\.stringValue)
        #expect(required.contains(argument))
    }

    /// A tool with no arguments still needs a schema, or clients complain.
    @Test(
        "argument-free tools still declare an object schema",
        arguments: [
            "list_projects", "list_users", "whoami",
        ])
    func argumentFreeToolsStillDeclareASchema(_ name: String) throws {
        let schema = try #require(Tools.named(name)).inputSchema
        #expect(schema["type"]?.stringValue == "object")
    }
}

@Suite("Configuration")
struct ConfigurationTests {

    private struct Store: CredentialStore {
        let stored: String?
        func token(forServer server: String) throws -> String? { stored }
        func store(_ token: String, forServer server: String) throws {}
        func remove(forServer server: String) throws {}
    }

    private func failureText(_ session: MCPSession) async throws -> String {
        let reply = try #require(
            await session.handle(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami"}}"#))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        return try #require(value["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
    }

    @Test("a missing URL explains what to set")
    func missingURLExplainsWhatToSet() async throws {
        let session = StdioServer.makeSession(
            environment: [:], credentials: Store(stored: nil))
        #expect(try await failureText(session).contains("ISSUES_URL"))
    }

    @Test("a missing token names the command that makes one")
    func missingTokenNamesTheCommand() async throws {
        let session = StdioServer.makeSession(
            environment: ["ISSUES_URL": "https://issues.example.test"],
            credentials: Store(stored: nil))
        let text = try await failureText(session)

        #expect(text.contains("ISSUES_TOKEN"))
        #expect(text.contains("auth token create"))
        #expect(text.contains("agent"))
    }

    /// So an agent on a machine where somebody has already run `issues auth login`
    /// works with no extra setup.
    @Test("a stored CLI credential is used when no token is in the environment")
    func storedCredentialIsUsed() async throws {
        let session = StdioServer.makeSession(
            environment: ["ISSUES_URL": "https://issues.example.test"],
            credentials: Store(stored: "issues_pat_stored"))

        // Configured, so the failure is a network one rather than a configuration
        // one.
        let text = try await failureText(session)
        #expect(!text.contains("ISSUES_TOKEN"))
    }

    /// Keyed by origin, matching the CLI, so a trailing slash does not produce a
    /// second invisible credential.
    @Test(
        "the credential key is the origin",
        arguments: [
            "https://issues.example.test", "https://issues.example.test/",
            "https://issues.example.test/api",
        ])
    func credentialKeyIsTheOrigin(_ raw: String) {
        #expect(
            StdioServer.originKey(for: URL(string: raw)!) == "https://issues.example.test")
    }

    @Test("a malformed URL is refused rather than half-used")
    func malformedURLIsRefused() async throws {
        let session = StdioServer.makeSession(
            environment: ["ISSUES_URL": "not a url", "ISSUES_TOKEN": "x"],
            credentials: Store(stored: nil))
        #expect(try await failureText(session).contains("ISSUES_URL"))
    }
}

/// Ticket 12: errors surface as the problem's title, detail and field errors
/// rendered as plain text an agent can act on — "title must not be empty", not a
/// bare status code.
@Suite("Error rendering")
struct ErrorRenderingTests {

    @Test("a validation failure names the field and what is wrong")
    func validationFailureNamesTheField() {
        let problem = Problem(
            type: "about:blank", title: "Invalid", status: 422, detail: "The request was rejected.",
            errors: [
                ValidationFailure(field: "title", code: .required, message: "A title is required.")
            ])

        let text = MCPSession.describe(APIError.invalidRequest(problem))
        #expect(text.contains("title"))
        #expect(text.contains("A title is required."))
    }

    /// An agent that retries through a 429 is the failure the limit exists to stop,
    /// so the message has to say the number and say not to.
    @Test("a rate limit says how long to wait and not to retry sooner")
    func rateLimitSaysHowLongToWait() {
        let text = MCPSession.describe(APIError.rateLimited(retryAfter: 42, problem: nil))

        #expect(text.contains("42"))
        #expect(text.lowercased().contains("not retry sooner"))
    }

    /// These strings go to a model and into logs, so "1 seconds" is worth avoiding.
    @Test(
        "the wait reads correctly in the singular and the plural",
        arguments: [
            (1.0, "1 second before"), (2.0, "2 seconds before"),
        ])
    func waitReadsCorrectly(seconds: TimeInterval, expected: String) {
        #expect(
            MCPSession.describe(APIError.rateLimited(retryAfter: seconds, problem: nil))
                .contains(expected))
    }

    /// Without a header there is still a sensible answer; leaving it unsaid invites
    /// an immediate retry.
    @Test("a rate limit with no header still gives a number")
    func rateLimitWithNoHeaderStillGivesANumber() {
        let text = MCPSession.describe(APIError.rateLimited(retryAfter: nil, problem: nil))
        #expect(text.range(of: "[0-9]+", options: .regularExpression) != nil)
    }

    /// An agent should learn its limits from the message rather than looping.
    @Test("a refusal explains what an agent token cannot do")
    func refusalExplainsAgentLimits() {
        let text = MCPSession.describe(APIError.forbidden(nil))
        #expect(text.contains("cannot"))
        #expect(text.contains("delete"))
    }

    @Test("a bad token points at the variable to fix")
    func badTokenPointsAtTheVariable() {
        #expect(MCPSession.describe(APIError.unauthenticated(nil)).contains("ISSUES_TOKEN"))
    }

    /// The distinction the server goes out of its way to make has to survive here.
    @Test("gone and not found read differently")
    func goneAndNotFoundReadDifferently() {
        let gone = MCPSession.describe(APIError.gone(nil))
        let missing = MCPSession.describe(APIError.notFound(nil))

        #expect(gone != missing)
        #expect(gone.lowercased().contains("deleted"))
    }

    @Test(
        "no rendering leaks an enum case",
        arguments: [
            APIError.notFound(nil), .conflict(nil), .server(status: 503, problem: nil),
            .unexpectedStatus(418), .forbidden(nil),
        ])
    func noRenderingLeaksAnEnumCase(_ error: APIError) {
        let text = MCPSession.describe(error)

        #expect(!text.isEmpty)
        #expect(!text.contains("APIError"))
        #expect(!text.contains("Optional("))
    }
}

@Suite("Session framing")
struct SessionFramingTests {

    private let session = MCPSession(configurationFailure: "not configured")

    /// A malformed line has to become a JSON-RPC error, not crash the loop: a host
    /// that sends one bad message must not lose the session.
    @Test(
        "a malformed line is answered with a parse error",
        arguments: [
            "not json", "{", #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
        ])
    func malformedLineIsAnsweredWithAnError(_ line: String) async throws {
        let reply = try #require(await session.handle(line))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))

        #expect(value["error"] != nil)
        #expect(value["id"] == .null)
    }

    /// Ids round-trip exactly, or a client cannot match a reply to its request.
    @Test(
        "the id comes back unchanged",
        arguments: [
            #"{"jsonrpc":"2.0","id":99,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"call-1","method":"ping"}"#,
        ])
    func idComesBackUnchanged(_ line: String) async throws {
        let reply = try #require(await session.handle(line))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        let sent = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))

        #expect(value["id"] == sent["id"])
    }
}
