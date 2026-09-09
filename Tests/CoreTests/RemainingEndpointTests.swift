import Core
import Foundation
import Testing

private func object(_ request: HTTPRequest) throws -> [String: Any] {
    let body = try #require(request.body)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Suite("Project endpoints")
struct ProjectEndpointTests {
    private let id = Project.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000002")!)

    @Test("lists and fetches at the collection and resource paths")
    func listsAndFetches() {
        #expect(ProjectEndpoints.list().path == "/api/v1/projects")
        #expect(
            ProjectEndpoints.get(id).path
                == "/api/v1/projects/018F3A9C-0000-7000-8000-000000000002")
    }

    @Test("creates with PUT at a caller-supplied id")
    func createsWithPUT() throws {
        let request = try ProjectEndpoints.create(
            id: id, ProjectCreate(key: try #require(ProjectKey("PROJ")), name: "Platform"))

        #expect(request.method == "PUT")
        #expect(try object(request)["key"] as? String == "PROJ")
    }

    /// Projects archive rather than delete, so there is no delete endpoint at all
    /// — archiving is a patch. See CONTEXT.md.
    @Test("archives through a patch, since there is no project deletion")
    func archivesThroughPatch() throws {
        var patch = ProjectPatch()
        patch.archived = .set(true)

        let request = try ProjectEndpoints.patch(id: id, patch)

        #expect(request.method == "PATCH")
        #expect(try object(request)["archived"] as? Bool == true)
    }

    /// The key is immutable after creation because it is baked into every Issue
    /// Key, so a patch cannot express changing it.
    @Test("a patch cannot change the project key")
    func patchCannotChangeKey() throws {
        var patch = ProjectPatch()
        patch.name = .set("Renamed")

        #expect(try object(ProjectEndpoints.patch(id: id, patch)).keys.sorted() == ["name"])
    }
}

@Suite("Label endpoints")
struct LabelEndpointTests {
    private let projectId = Project.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000002")!)
    private let labelId = Label.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000003")!)

    /// Labels are nested under their Project because they are project-scoped by
    /// definition; a bare /labels would be meaningless. See ticket 06.
    @Test("labels are nested under their project")
    func labelsAreNested() {
        #expect(
            LabelEndpoints.list(projectId: projectId).path
                == "/api/v1/projects/018F3A9C-0000-7000-8000-000000000002/labels")
    }

    @Test("creates at the derived id and can be renamed or recoloured")
    func createsAndPatches() throws {
        let create = try LabelEndpoints.create(
            projectId: projectId,
            LabelCreate(name: "backend", color: "#2D6CDF"))
        #expect(create.method == "PUT")
        #expect(
            create.path.hasSuffix(
                "/labels/\(Label.deriveID(projectId: projectId, name: "backend").rawValue.uuidString)"))

        var patch = LabelPatch()
        patch.color = .set("#0E8A6B")
        #expect(
            try object(LabelEndpoints.patch(projectId: projectId, id: labelId, patch))["color"] as? String
                == "#0E8A6B")
    }

    @Test("deleting a label addresses it within its project")
    func deletesWithinProject() {
        let request = LabelEndpoints.delete(projectId: projectId, id: labelId)

        #expect(request.method == "DELETE")
        #expect(request.path.hasSuffix("/labels/018F3A9C-0000-7000-8000-000000000003"))
    }
}

@Suite("Comment endpoints")
struct CommentEndpointTests {
    private let issueId = Core.Issue.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000020")!)
    private let commentId = Core.Comment.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000010")!)

    /// The collection is nested under its Issue; the individual resource is
    /// top-level, matching how Issues themselves are addressed.
    @Test("comments list under their issue and are addressed top-level")
    func listAndResourcePaths() {
        #expect(
            CommentEndpoints.list(issueId: issueId).path
                == "/api/v1/issues/018F3A9C-0000-7000-8000-000000000020/comments")
        #expect(
            CommentEndpoints.get(commentId).path
                == "/api/v1/comments/018F3A9C-0000-7000-8000-000000000010")
    }

    /// PUT, not POST. ADR 0005's reasoning applies here exactly as it does to
    /// Issues: an offline client retrying a create it never saw a response to
    /// must not post the same comment twice.
    @Test("creates with PUT at a caller-supplied id, not POST")
    func createsWithPUT() throws {
        let request = try CommentEndpoints.create(
            id: commentId, CommentCreate(issueId: issueId, body: "Looks right."))

        #expect(request.method == "PUT")
        #expect(try object(request)["body"] as? String == "Looks right.")
        #expect(try object(request)["issueId"] as? String == "018F3A9C-0000-7000-8000-000000000020")
    }

    @Test("only the body is editable")
    func onlyBodyIsEditable() throws {
        var patch = CommentPatch()
        patch.body = .set("Edited.")

        #expect(try object(CommentEndpoints.patch(id: commentId, patch)).keys.sorted() == ["body"])
    }
}

@Suite("User and instance endpoints")
struct UserEndpointTests {
    private let id = User.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000001")!)

    @Test("users list, fetch, and expose the caller")
    func userPaths() {
        #expect(UserEndpoints.list().path == "/api/v1/users")
        #expect(UserEndpoints.get(id).path == "/api/v1/users/018F3A9C-0000-7000-8000-000000000001")
        #expect(UserEndpoints.me().path == "/api/v1/users/me")
    }

    /// Users are deactivated, never deleted, so there is no delete endpoint —
    /// deactivation is a patch.
    @Test("deactivation is a patch, not a delete")
    func deactivationIsAPatch() throws {
        var patch = UserPatch()
        patch.active = .set(false)

        let request = try UserEndpoints.patch(id: id, patch)

        #expect(request.method == "PATCH")
        #expect(try object(request)["active"] as? Bool == false)
    }

    @Test("meta is versioned and health is not")
    func metaAndHealth() {
        #expect(InstanceEndpoints.meta().path == "/api/v1/meta")
        // Unversioned and unauthenticated, so a probe keeps working across an
        // API version change. See ticket 06.
        #expect(InstanceEndpoints.health().path == "/health")
    }

    @Test("server metadata decodes")
    func metaDecodes() throws {
        let json = """
            {"serverVersion":"1.4.2","apiVersions":["v1"],"instanceName":"Trywe"}
            """

        let meta = try JSONCoders.decoder.decode(ServerMeta.self, from: Data(json.utf8))

        #expect(meta.serverVersion == "1.4.2")
        #expect(meta.apiVersions == ["v1"])
        #expect(meta.instanceName == "Trywe")
    }
}

@Suite("Endpoint coverage gaps")
struct EndpointCoverageTests {
    private let userId = User.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000001")!)
    private let commentId = Core.Comment.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000010")!)
    private let issueId = Core.Issue.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000020")!)

    @Test("deleting a comment tombstones it by id")
    func deletesComment() {
        let request = CommentEndpoints.delete(commentId)

        #expect(request.method == "DELETE")
        #expect(request.path == "/api/v1/comments/018F3A9C-0000-7000-8000-000000000010")
    }

    /// Admin-only in practice, but the endpoint shape is the same; enforcement is
    /// the server's (ticket 07).
    @Test("creating a user is a PUT with a caller-supplied id")
    func createsUser() throws {
        let request = try UserEndpoints.create(
            id: userId, UserCreate(email: "jo@example.com", displayName: "Jo", role: .admin))

        #expect(request.method == "PUT")
        let body = try object(request)
        #expect(body["email"] as? String == "jo@example.com")
        #expect(body["role"] as? String == "admin")
    }

    /// A cursor only ever comes back from a previous response, so this checks it
    /// is passed through on the collections that paginate.
    @Test("cursors are passed through on every paginated collection")
    func cursorsPassThrough() {
        let cursor = "eyJzIjoxfQ"

        for request in [
            ProjectEndpoints.list(page: Pagination(cursor: cursor, limit: 10)),
            UserEndpoints.list(page: Pagination(cursor: cursor, limit: 10)),
            CommentEndpoints.list(issueId: issueId, page: Pagination(cursor: cursor, limit: 10)),
        ] {
            let query = Dictionary(uniqueKeysWithValues: request.query.map { ($0.name, $0.value) })
            #expect(query["cursor"] == cursor)
            #expect(query["limit"] == "10")
        }
    }
}
