import Core
import Foundation
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

@Suite("Application and project routes")
struct ProjectRoutesTests {

    private func withServer(
        role: Role = .admin,
        _ body:
            @Sendable @escaping (any TestClientProtocol, String, AppDatabase) async throws ->
            Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: role)
        try UserRepository(database: database).save(user)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: nil)

        let app = Application(router: IssuesRouter.build(database: database))
        try await app.test(.router) { client in
            try await body(client, token.raw, database)
        }
    }

    private func auth(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    /// Unversioned and unauthenticated, so a liveness probe keeps working across
    /// an API version change and needs no credentials (ticket 06).
    @Test("health needs no credentials and is unversioned")
    func healthIsOpen() async throws {
        try await withServer { client, _, _ in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("meta requires credentials and reports the instance")
    func metaRequiresCredentials() async throws {
        try await withServer { client, token, _ in
            try await client.execute(uri: "/api/v1/meta", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(
                uri: "/api/v1/meta", method: .get, headers: auth(token)
            ) { response in
                #expect(response.status == .ok)
                let meta = try JSONCoders.decoder.decode(
                    ServerMeta.self, from: Data(buffer: response.body))
                #expect(meta.apiVersions.contains("v1"))
                #expect(meta.serverVersion.isEmpty == false)
            }
        }
    }

    @Test("an unknown project is not found, as a problem document")
    func unknownProjectIsNotFound() async throws {
        try await withServer { client, token, _ in
            try await client.execute(
                uri: "/api/v1/projects/\(UUID().uuidString)", method: .get, headers: auth(token)
            ) { response in
                #expect(response.status == .notFound)
                #expect(
                    response.headers[.contentType]?.contains("application/problem+json") == true)
            }
        }
    }

    /// PUT at a caller-supplied id, so an offline retry cannot create twice.
    @Test("creating a project returns it, and the same request again is idempotent")
    func createIsIdempotent() async throws {
        try await withServer { client, token, _ in
            let id = UUID().uuidString
            let body = #"{"key":"PROJ","name":"Platform","description":"Server work"}"#

            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .put, headers: auth(token),
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .created)
                let project = try JSONCoders.decoder.decode(
                    Project.self, from: Data(buffer: response.body))
                #expect(project.key == ProjectKey("PROJ"))
            }

            // The retry an offline client makes when it never saw the response.
            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .put, headers: auth(token),
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// A PUT to an existing id with different content is a conflict, not a
    /// silent overwrite — PUT here is create-only (ADR 0005).
    @Test("re-creating an id with different content is a conflict")
    func recreateWithDifferentContentConflicts() async throws {
        try await withServer { client, token, _ in
            let id = UUID().uuidString

            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .put, headers: auth(token),
                body: ByteBuffer(string: #"{"key":"PROJ","name":"Platform","description":""}"#)
            ) { response in
                #expect(response.status == .created)
            }

            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .put, headers: auth(token),
                body: ByteBuffer(string: #"{"key":"OTHER","name":"Different","description":""}"#)
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    /// The end-to-end proof that Merge Patch works over the wire: a field the
    /// caller did not mention must survive untouched.
    @Test("a patch changes only the fields it names")
    func patchChangesOnlyNamedFields() async throws {
        try await withServer { client, token, _ in
            let id = UUID().uuidString
            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .put, headers: auth(token),
                body: ByteBuffer(
                    string: #"{"key":"PROJ","name":"Platform","description":"Keep me"}"#)
            ) { _ in }

            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .patch, headers: auth(token),
                body: ByteBuffer(string: #"{"name":"Renamed"}"#)
            ) { response in
                #expect(response.status == .ok)
                let project = try JSONCoders.decoder.decode(
                    Project.self, from: Data(buffer: response.body))
                #expect(project.name == "Renamed")
                #expect(project.description == "Keep me", "an unmentioned field was overwritten")
            }
        }
    }

    @Test("archiving is a patch")
    func archivingIsAPatch() async throws {
        try await withServer { client, token, _ in
            let id = UUID().uuidString
            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .put, headers: auth(token),
                body: ByteBuffer(string: #"{"key":"PROJ","name":"Platform","description":""}"#)
            ) { _ in }

            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .patch, headers: auth(token),
                body: ByteBuffer(string: #"{"archived":true}"#)
            ) { response in
                let project = try JSONCoders.decoder.decode(
                    Project.self, from: Data(buffer: response.body))
                #expect(project.archived)
            }
        }
    }

    @Test("listing returns a paginated envelope")
    func listingIsPaginated() async throws {
        try await withServer { client, token, _ in
            for key in ["ONE", "TWO"] {
                try await client.execute(
                    uri: "/api/v1/projects/\(UUID().uuidString)", method: .put,
                    headers: auth(token),
                    body: ByteBuffer(string: #"{"key":"\#(key)","name":"P","description":""}"#)
                ) { _ in }
            }

            try await client.execute(
                uri: "/api/v1/projects", method: .get, headers: auth(token)
            ) { response in
                #expect(response.status == .ok)
                let page = try JSONCoders.decoder.decode(
                    Paginated<Project>.self, from: Data(buffer: response.body))
                #expect(page.items.count == 2)
            }
        }
    }

    /// The wire conventions from ticket 06, asserted on the raw payload rather
    /// than through a round trip that would hide them.
    @Test("responses use camelCase keys and RFC 3339 instants")
    func responsesFollowWireConventions() async throws {
        try await withServer { client, token, _ in
            let id = UUID().uuidString
            try await client.execute(
                uri: "/api/v1/projects/\(id)", method: .put, headers: auth(token),
                body: ByteBuffer(string: #"{"key":"PROJ","name":"Platform","description":""}"#)
            ) { response in
                let object = try #require(
                    JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any])
                #expect(object["createdAt"] is String)
                let created = try #require(object["createdAt"] as? String)
                #expect(created.hasSuffix("Z"))
                #expect(created.contains("T"))
            }
        }
    }

    /// Validation failures arrive as field-level errors clients branch on by code.
    @Test("an invalid body is rejected with field-level errors")
    func invalidBodyIsRejected() async throws {
        try await withServer { client, token, _ in
            try await client.execute(
                uri: "/api/v1/projects/\(UUID().uuidString)", method: .put, headers: auth(token),
                body: ByteBuffer(string: #"{"key":"PROJ","name":"   ","description":""}"#)
            ) { response in
                #expect(response.status == .unprocessableContent)
                let problem = try JSONCoders.decoder.decode(
                    Problem.self, from: Data(buffer: response.body))
                #expect(problem.errors?.contains { $0.field == "name" } == true)
            }
        }
    }

    /// Members do tracker work; Admins manage the Instance (CONTEXT.md).
    @Test("a member may not create a project")
    func memberMayNotCreateAProject() async throws {
        try await withServer(role: .member) { client, token, _ in
            try await client.execute(
                uri: "/api/v1/projects/\(UUID().uuidString)", method: .put, headers: auth(token),
                body: ByteBuffer(string: #"{"key":"PROJ","name":"Platform","description":""}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}

@Suite("Fetching a project")
struct ProjectFetchTests {

    /// The 404 path was covered before this; the success path was not, which is
    /// the more important of the two.
    @Test("a created project can be fetched back by id")
    func createdProjectCanBeFetched() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .admin)
        try UserRepository(database: database).save(user)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: nil)
        let id = UUID()
        try ProjectRepository(database: database).save(
            Project.fixture(id: Project.ID(id), name: "Platform"))

        try await Application(router: IssuesRouter.build(database: database)).test(.router) {
            client in
            try await client.execute(
                uri: "/api/v1/projects/\(id.uuidString)", method: .get,
                headers: [.authorization: "Bearer \(token.raw)"]
            ) { response in
                #expect(response.status == .ok)
                let project = try JSONCoders.decoder.decode(
                    Project.self, from: Data(buffer: response.body))
                #expect(project.name == "Platform")
                #expect(project.id == Project.ID(id))
            }
        }
    }
}

@Suite("Route edge cases")
struct RouteEdgeCaseTests {

    @Test("a path that is not a UUID is not found rather than a server error")
    func nonUUIDPathIsNotFound() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .admin)
        try UserRepository(database: database).save(user)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: nil)

        try await Application(router: IssuesRouter.build(database: database)).test(.router) {
            client in
            try await client.execute(
                uri: "/api/v1/projects/not-a-uuid", method: .get,
                headers: [.authorization: "Bearer \(token.raw)"]
            ) { response in
                #expect(response.status == .notFound)
            }
            // Patching something that does not exist is also not found, rather
            // than creating it — PATCH is not an upsert.
            try await client.execute(
                uri: "/api/v1/projects/\(UUID().uuidString)", method: .patch,
                headers: [
                    .authorization: "Bearer \(token.raw)", .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"name":"Nope"}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// A name over the limit is rejected on patch as well as on create; a
    /// validation rule enforced on only one path is not enforced.
    @Test("an over-long name is rejected on patch too")
    func overLongNameRejectedOnPatch() async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: .admin)
        try UserRepository(database: database).save(user)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: .human, deviceId: nil)
        let id = UUID()
        try ProjectRepository(database: database).save(Project.fixture(id: Project.ID(id)))

        let tooLong = String(repeating: "a", count: Validation.maxProjectNameCharacters + 1)
        try await Application(router: IssuesRouter.build(database: database)).test(.router) {
            client in
            try await client.execute(
                uri: "/api/v1/projects/\(id.uuidString)", method: .patch,
                headers: [
                    .authorization: "Bearer \(token.raw)", .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"name":"\#(tooLong)"}"#)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }
}

@Suite("Server plumbing")
struct ServerPlumbingTests {

    /// Ticket 09's layout, asserted without creating anything on disk.
    @Test("the database path sits under Application Support")
    func databasePathIsUnderApplicationSupport() {
        let url = ServerEntryPoint.databaseURL(
            applicationSupport: URL(filePath: "/Users/someone/Library/Application Support"))

        #expect(
            url.path == "/Users/someone/Library/Application Support/Issues/issues.sqlite")
    }

    /// Ticket 09: loopback by default, so cleartext exposure takes a deliberate act.
    @Test("the default bind address is loopback")
    func defaultBindIsLoopback() {
        #expect(ServerEntryPoint.defaultHost == "127.0.0.1")
    }

    @Test("an instance reports its name and a non-empty epoch")
    func instanceReportsNameAndEpoch() throws {
        let database = try AppDatabase.inMemory()
        let instance = InstanceRepository(database: database)

        #expect(try instance.name() == "Issues")
        #expect(try instance.epoch().isEmpty == false)
    }

    /// 410 is distinct from 404 all the way to the wire: ticket 11 gives them
    /// different CLI exit codes.
    @Test("gone renders as 410 with its own problem type")
    func goneRendersAs410() {
        let error = ProblemError.gone(detail: "It was deleted.")

        #expect(error.status == .gone)
        #expect(error.problem.status == 410)
        #expect(error.problem.type != ProblemError.notFound().problem.type)
    }
}

@Suite("Database directory")
struct DatabaseDirectoryTests {

    /// The directory holds every issue *and* every session hash, so 0700 is not
    /// housekeeping. Tested against a temporary path so it leaves nothing in the
    /// developer's home.
    @Test("the database directory is created private to its owner")
    func directoryIsCreatedPrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "issues-dir-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let url = ServerEntryPoint.databaseURL(applicationSupport: root)
        try ServerEntryPoint.prepareDirectory(at: url)

        let directory = url.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: directory.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o700)
    }
}
