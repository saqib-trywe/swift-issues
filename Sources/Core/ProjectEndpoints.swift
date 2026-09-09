import Foundation

public struct ProjectCreate: Codable, Sendable {
    public var key: ProjectKey
    public var name: String
    public var description: String

    public init(key: ProjectKey, name: String, description: String = "") {
        self.key = key
        self.name = name
        self.description = description
    }
}

/// `key` is absent deliberately: it is immutable after creation because it is
/// baked into every Issue Key, so changing it is not expressible.
public struct ProjectPatch: Codable, Sendable {
    public var name: Settable<String> = .unchanged
    public var description: Settable<String> = .unchanged
    public var archived: Settable<Bool> = .unchanged

    public init() {}
}

/// Requests for the Project resource.
///
/// There is no delete: Projects archive, because their Issues and Issue Keys
/// outlive them. Archiving is a patch. See CONTEXT.md.
public enum ProjectEndpoints {
    static let base = "/api/v1/projects"

    public static func list(page: Pagination = Pagination()) -> HTTPRequest {
        HTTPRequest(method: "GET", path: base, query: pageQuery(page))
    }

    public static func get(_ id: Project.ID) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "\(base)/\(id.rawValue.uuidString)")
    }

    public static func create(id: Project.ID, _ body: ProjectCreate) throws -> HTTPRequest {
        HTTPRequest(
            method: "PUT", path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(body))
    }

    public static func patch(id: Project.ID, _ body: ProjectPatch) throws -> HTTPRequest {
        HTTPRequest(
            method: "PATCH", path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/merge-patch+json"],
            body: try JSONCoders.encoder.encode(body))
    }
}

/// Shared page parameters. Cursors are opaque and only ever come from a response.
func pageQuery(_ page: Pagination) -> [(name: String, value: String)] {
    var query: [(name: String, value: String)] = []
    if let cursor = page.cursor { query.append((name: "cursor", value: cursor)) }
    query.append((name: "limit", value: String(page.limit)))
    return query
}
