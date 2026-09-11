import Core
import Foundation
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

private typealias Issue = Core.Issue

/// Bodies are built with `JSONSerialization` rather than string concatenation.
///
/// The first version of this file assembled JSON with chains of `String + String`.
/// Each `+` is heavily overloaded, and a chain of five or six sent the type checker
/// exponential: the test target took over nine minutes to compile. This is a
/// compile-time requirement, not a style preference.
private func json(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func labelJSON(name: String, color: String) throws -> String {
    try json(["name": name, "color": color])
}

private func deltaJSON(add: [String], remove: [String]) throws -> String {
    try json(["add": add, "remove": remove])
}

@Suite("Label routes")
struct LabelRoutesTests {

    private struct Harness: Sendable {
        let client: any TestClientProtocol
        let token: String
        let project: Project
        let other: Project
        let issue: Issue
        let database: AppDatabase
    }

    private func withServer(
        role: Role = .member,
        kind: TokenKind = .human,
        _ body: @Sendable @escaping (Harness) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = User.fixture(role: role)
        try UserRepository(database: database).save(user)
        let projects = ProjectRepository(database: database)
        let project = Project.fixture(key: ProjectKey("PROJ")!)
        let other = Project.fixture(id: Project.ID(), key: ProjectKey("OTHER")!)
        try projects.save(project)
        try projects.save(other)
        let draft = Issue.fixture(key: nil, projectId: project.id, reporterId: user.id)
        let issue = try IssueRepository(database: database).create(draft)
        let token = try SessionRepository(database: database).create(
            for: user.id, kind: kind, deviceId: nil)

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            let harness = Harness(
                client: client, token: token.raw, project: project, other: other,
                issue: issue, database: database)
            try await body(harness)
        }
    }

    private func headers(_ token: String) -> HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(token)"
        fields[.contentType] = "application/json"
        return fields
    }

    private func labelURI(_ project: Project, _ id: Label.ID) -> String {
        let projectId: String = project.id.rawValue.uuidString
        let labelId: String = id.rawValue.uuidString
        return "/api/v1/projects/\(projectId)/labels/\(labelId)"
    }

    private func labelsURI(_ project: Project) -> String {
        let projectId: String = project.id.rawValue.uuidString
        return "/api/v1/projects/\(projectId)/labels"
    }

    private func membershipURI(_ issue: Issue) -> String {
        let issueId: String = issue.id.rawValue.uuidString
        return "/api/v1/issues/\(issueId)/labels"
    }

    /// Labels are created at an id derived from (project, name) so two clients
    /// creating "backend" offline converge rather than producing duplicates.
    @Test("creating a label at its derived id succeeds")
    func createAtDerivedID() async throws {
        try await withServer { h in
            let id: Label.ID = Label.deriveID(projectId: h.project.id, name: "backend")
            let json: String = try labelJSON(name: "backend", color: "#2D6CDF")

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { response in
                #expect(response.status == .created)
                let label = try JSONCoders.decoder.decode(
                    Label.self, from: Data(buffer: response.body))
                #expect(label.name == "backend")
                #expect(label.id == id)
            }
        }
    }

    /// The convergence property rests on the id being derived. An id a client
    /// invented would let two clients create the same label twice, which is exactly
    /// what ADR 0003 chose derivation to prevent.
    @Test("creating a label at an invented id is refused")
    func createAtInventedIDIsRefused() async throws {
        try await withServer { h in
            let json: String = try labelJSON(name: "backend", color: "#2D6CDF")

            try await h.client.execute(
                uri: self.labelURI(h.project, Label.ID()), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }

    @Test("the same label created twice converges instead of duplicating")
    func sameLabelConverges() async throws {
        try await withServer { h in
            let id: Label.ID = Label.deriveID(projectId: h.project.id, name: "backend")
            let json: String = try labelJSON(name: "backend", color: "#2D6CDF")

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { response in
                #expect(response.status == .created)
            }
            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { response in
                #expect(response.status == .ok)
            }

            try await h.client.execute(
                uri: self.labelsURI(h.project), method: .get, headers: self.headers(h.token)
            ) { response in
                let page = try JSONCoders.decoder.decode(
                    Paginated<Label>.self, from: Data(buffer: response.body))
                #expect(page.items.count == 1, "the same label was stored twice")
            }
        }
    }

    /// Derivation is a creation-time device only: after a rename the id no longer
    /// corresponds to the name, which is fine because the id is opaque thereafter.
    @Test("a label can be renamed and recoloured, keeping its id")
    func renameKeepsTheID() async throws {
        try await withServer { h in
            let id: Label.ID = Label.deriveID(projectId: h.project.id, name: "backend")
            let created: String = try labelJSON(name: "backend", color: "#2D6CDF")
            let renamed: String = try labelJSON(name: "back-end", color: "#0E8A6B")

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: created)
            ) { _ in }

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .patch,
                headers: self.headers(h.token), body: ByteBuffer(string: renamed)
            ) { response in
                #expect(response.status == .ok)
                let label = try JSONCoders.decoder.decode(
                    Label.self, from: Data(buffer: response.body))
                #expect(label.name == "back-end")
                #expect(label.color == "#0E8A6B")
                #expect(label.id == id, "the id changed with the name")
            }
        }
    }

    @Test("a blank label name is rejected")
    func blankNameIsRejected() async throws {
        try await withServer { h in
            let id: Label.ID = Label.deriveID(projectId: h.project.id, name: "   ")
            let json: String = try labelJSON(name: "   ", color: "#2D6CDF")

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }

    @Test("deleting a label tombstones it and drops it from the listing")
    func deleteTombstones() async throws {
        try await withServer { h in
            let id: Label.ID = Label.deriveID(projectId: h.project.id, name: "backend")
            let json: String = try labelJSON(name: "backend", color: "#2D6CDF")

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { _ in }

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .delete,
                headers: self.headers(h.token)
            ) { response in
                #expect(response.status == .noContent)
            }

            try await h.client.execute(
                uri: self.labelsURI(h.project), method: .get, headers: self.headers(h.token)
            ) { response in
                let page = try JSONCoders.decoder.decode(
                    Paginated<Label>.self, from: Data(buffer: response.body))
                #expect(page.items.isEmpty)
            }
        }
    }

    /// Membership is changed as a delta so two people adding different labels
    /// concurrently both survive; the link records stay internal to sync.
    @Test("labels are added to and removed from an issue as a delta")
    func membershipIsADelta() async throws {
        try await withServer { h in
            let bug: Label.ID = Label.deriveID(projectId: h.project.id, name: "bug")
            let ux: Label.ID = Label.deriveID(projectId: h.project.id, name: "ux")

            try await h.client.execute(
                uri: self.labelURI(h.project, bug), method: .put,
                headers: self.headers(h.token),
                body: ByteBuffer(string: try labelJSON(name: "bug", color: "#c0392b"))
            ) { _ in }
            try await h.client.execute(
                uri: self.labelURI(h.project, ux), method: .put,
                headers: self.headers(h.token),
                body: ByteBuffer(string: try labelJSON(name: "ux", color: "#7d3fb5"))
            ) { _ in }

            let addBoth: String = try deltaJSON(
                add: [bug.rawValue.uuidString, ux.rawValue.uuidString], remove: [])
            try await h.client.execute(
                uri: self.membershipURI(h.issue), method: .patch,
                headers: self.headers(h.token), body: ByteBuffer(string: addBoth)
            ) { response in
                #expect(response.status == .ok)
            }

            let labels = LabelRepository(database: h.database)
            let afterAdd: [Label.ID] = try labels.labelIds(for: h.issue.id)
            #expect(afterAdd.count == 2)
            #expect(afterAdd.contains(bug))
            #expect(afterAdd.contains(ux))

            let removeOne: String = try deltaJSON(add: [], remove: [ux.rawValue.uuidString])
            try await h.client.execute(
                uri: self.membershipURI(h.issue), method: .patch,
                headers: self.headers(h.token), body: ByteBuffer(string: removeOne)
            ) { _ in }

            let afterRemove: [Label.ID] = try labels.labelIds(for: h.issue.id)
            #expect(afterRemove == [bug])
        }
    }

    /// The cross-entity invariant: a Label belongs to one Project, and applying it
    /// outside that Project would let project-scoped labels leak between projects.
    @Test("a label from another project cannot be applied")
    func crossProjectLabelIsRefused() async throws {
        try await withServer { h in
            let foreign: Label.ID = Label.deriveID(projectId: h.other.id, name: "backend")
            let json: String = try labelJSON(name: "backend", color: "#2D6CDF")

            try await h.client.execute(
                uri: self.labelURI(h.other, foreign), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { response in
                #expect(response.status == .created)
            }

            let delta: String = try deltaJSON(add: [foreign.rawValue.uuidString], remove: [])
            try await h.client.execute(
                uri: self.membershipURI(h.issue), method: .patch,
                headers: self.headers(h.token), body: ByteBuffer(string: delta)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }

            let applied: [Label.ID] = try LabelRepository(database: h.database)
                .labelIds(for: h.issue.id)
            #expect(applied.isEmpty)
        }
    }

    @Test("applying a label that does not exist is refused")
    func unknownLabelIsRefused() async throws {
        try await withServer { h in
            let delta: String = try deltaJSON(add: [UUID().uuidString], remove: [])

            try await h.client.execute(
                uri: self.membershipURI(h.issue), method: .patch,
                headers: self.headers(h.token), body: ByteBuffer(string: delta)
            ) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }

    /// An agent may write, so it may label; it may not delete.
    @Test("an agent may label an issue but not delete a label")
    func agentMayLabelButNotDelete() async throws {
        try await withServer(kind: .agent) { h in
            let id: Label.ID = Label.deriveID(projectId: h.project.id, name: "bug")
            let json: String = try labelJSON(name: "bug", color: "#c0392b")

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .put,
                headers: self.headers(h.token), body: ByteBuffer(string: json)
            ) { response in
                #expect(response.status == .created)
            }

            try await h.client.execute(
                uri: self.labelURI(h.project, id), method: .delete,
                headers: self.headers(h.token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
