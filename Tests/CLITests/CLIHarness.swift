import Core
import Credentials
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Synchronization
import TestSupport

@testable import CLI
@testable import Server

/// Dispatches a Core `HTTPRequest` straight into the real router.
///
/// This is why CLI tests are worth having: the commands run against real
/// routing, real authentication and a real database, with no socket and no
/// canned responses. A contract change that breaks the CLI fails here rather
/// than in a SwiftUI view months later.
struct RouterTransport: HTTPTransport {
    let client: any TestClientProtocol

    func send(_ request: Core.HTTPRequest) async throws -> Core.HTTPResponse {
        var components = URLComponents()
        components.path = request.path
        if !request.query.isEmpty {
            components.queryItems = request.query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        // `URLComponents` is what the real transport uses, so encoding bugs show
        // up here too rather than only in production.
        let uri = components.string ?? request.path

        var headers = HTTPFields()
        for (name, value) in request.headers {
            guard let field = HTTPField.Name(name) else { continue }
            headers[field] = value
        }

        return try await client.execute(
            uri: uri,
            method: .init(rawValue: request.method) ?? .get,
            headers: headers,
            body: request.body.map { ByteBuffer(data: $0) }
        ) { response in
            var received: [String: String] = [:]
            for field in response.headers { received[field.name.canonicalName] = field.value }
            return Core.HTTPResponse(
                status: Int(response.status.code),
                headers: received,
                body: Data(buffer: response.body))
        }
    }
}

/// Collects written text so output can be asserted.
final class RecordingSink: TextSink {
    private let storage = Mutex<String>("")

    func write(_ text: String) {
        storage.withLock { $0 += text }
    }

    var text: String { storage.withLock { $0 } }
}

/// One invocation's captured output.
struct CapturedOutput {
    let code: Int32
    let standardOutput: String
    let standardError: String

    /// Non-empty lines, for asserting on a table without depending on padding.
    var outputLines: [String] {
        standardOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// A running instance plus everything needed to invoke the CLI against it.
struct CLIWorld: Sendable {
    let database: AppDatabase
    let transport: RouterTransport
    let credentials: any CredentialStore
    let directory: URL
    let owner: User
    let project: Project
    static let password = "correct horse battery staple"

    var configurationFile: URL { directory.appending(path: "config.toml") }

    /// Runs the CLI exactly as the binary would, returning its exit code and
    /// both streams.
    func run(
        _ arguments: [String],
        environment: [String: String] = [:],
        isInputTerminal: Bool = false,
        input: [String] = [],
        secrets: [String] = [],
        standardInput: String = "",
        editor: (@Sendable (String) throws -> String?)? = nil
    ) async -> CapturedOutput {
        let out = RecordingSink()
        let error = RecordingSink()
        let lines = Mutex<[String]>(input)
        let passwords = Mutex<[String]>(secrets)

        let terminal = Terminal(
            output: out,
            error: error,
            // Off by default so tests exercise the non-interactive path, which is
            // the one CI runs and the one that must never block.
            isOutputTerminal: false,
            isInputTerminal: isInputTerminal,
            readLine: { lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
            readSecret: { passwords.withLock { $0.isEmpty ? nil : $0.removeFirst() } }
        )

        var resolved = environment
        if resolved["ISSUES_URL"] == nil && resolved["ISSUES_NO_URL"] == nil {
            resolved["ISSUES_URL"] = "https://issues.example.test"
        }
        resolved["ISSUES_NO_URL"] = nil

        let context = CommandContext(
            terminal: terminal,
            environment: resolved,
            workingDirectory: directory,
            configurationFile: configurationFile,
            credentials: credentials,
            transport: { _ in transport },
            // Defaults to abandoning the edit, so a command that unexpectedly
            // reaches for an editor fails loudly rather than inventing text.
            openEditor: editor ?? { _ in nil },
            readStandardInput: { standardInput }
        )

        let code = await IssuesCLI.run(arguments: arguments, context: context)
        return CapturedOutput(code: code, standardOutput: out.text, standardError: error.text)
    }

    /// Authenticates as an ordinary Member, for the Admin-only rejections.
    func authenticateAsMember() throws {
        let member = User.fixture(
            email: "member@example.com", displayName: "Mel", role: .member)
        try UserRepository(database: database).save(member)
        let session = try SessionRepository(database: database).create(
            for: member.id, kind: .human, deviceId: nil, label: "cli tests")
        try credentials.store(session.raw, forServer: "https://issues.example.test")
    }

    /// Stores a working token, so tests of authenticated commands do not each
    /// have to log in first.
    func authenticate() throws {
        let session = try SessionRepository(database: database).create(
            for: owner.id, kind: .human, deviceId: nil, label: "cli tests")
        try credentials.store(session.raw, forServer: "https://issues.example.test")
    }
}

/// Builds an instance with one Admin, one Project, and whatever issues a test asks for.
func withCLI(
    issues: [Issue] = [],
    configuresProject: Bool = true,
    _ body: @Sendable @escaping (CLIWorld) async throws -> Void
) async throws {
    let database = try AppDatabase.inMemory()

    let owner = User.fixture(email: "saqib@example.com", displayName: "Saqib", role: .admin)
    let users = UserRepository(database: database)
    try users.save(owner)
    // Cheap parameters: the stored hash records its own, so verification against
    // the router's production hasher still works.
    try users.setPassword(try PasswordHasher.testing.hash(CLIWorld.password), for: owner.id)

    let project = Project.fixture()
    try ProjectRepository(database: database).save(project)

    let repository = IssueRepository(database: database)
    for issue in issues {
        // `create` allocates the Issue Key from the project's counter, so the keys
        // in these tests are the ones the server would really hand out.
        _ = try repository.create(issue)
    }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "issues-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Most commands need a project to act on, and spelling --project on every
    // invocation would bury the thing each test is actually about.
    if configuresProject {
        try "project = \"\(project.key.wireValue)\"\n".write(
            to: directory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    }

    let application = Application(router: IssuesRouter.build(database: database))
    try await application.test(.router) { client in
        try await body(
            CLIWorld(
                database: database,
                transport: RouterTransport(client: client),
                credentials: FileCredentialStore(
                    file: directory.appending(path: "credentials")),
                directory: directory,
                owner: owner,
                project: project))
    }
}
