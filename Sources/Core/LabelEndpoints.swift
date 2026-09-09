import Foundation

public struct LabelCreate: Codable, Sendable {
    public var name: String
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

public struct LabelPatch: Codable, Sendable {
    public var name: Settable<String> = .unchanged
    public var color: Settable<String> = .unchanged

    public init() {}
}

/// Requests for the Label resource.
///
/// Nested under its Project throughout: a Label is project-scoped by definition,
/// so a bare `/labels` would be meaningless, and a Label may only be applied to
/// Issues in the Project that owns it. See ticket 06.
public enum LabelEndpoints {

    static func base(_ projectId: Project.ID) -> String {
        "\(ProjectEndpoints.base)/\(projectId.rawValue.uuidString)/labels"
    }

    public static func list(projectId: Project.ID) -> HTTPRequest {
        HTTPRequest(method: "GET", path: base(projectId))
    }

    /// Created at its derived id, so two clients creating the same label offline
    /// converge rather than producing duplicates. See ADR 0003.
    public static func create(projectId: Project.ID, _ body: LabelCreate) throws -> HTTPRequest {
        let id = Label.deriveID(projectId: projectId, name: body.name)
        return HTTPRequest(
            method: "PUT", path: "\(base(projectId))/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(body))
    }

    public static func patch(
        projectId: Project.ID, id: Label.ID, _ body: LabelPatch
    ) throws -> HTTPRequest {
        HTTPRequest(
            method: "PATCH", path: "\(base(projectId))/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/merge-patch+json"],
            body: try JSONCoders.encoder.encode(body))
    }

    public static func delete(projectId: Project.ID, id: Label.ID) -> HTTPRequest {
        HTTPRequest(method: "DELETE", path: "\(base(projectId))/\(id.rawValue.uuidString)")
    }
}
