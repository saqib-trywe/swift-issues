import Foundation

public struct UserCreate: Codable, Sendable {
    public var email: String
    public var displayName: String
    public var role: Role

    public init(email: String, displayName: String, role: Role = .member) {
        self.email = email
        self.displayName = displayName
        self.role = role
    }
}

public struct UserPatch: Codable, Sendable {
    public var displayName: Settable<String> = .unchanged
    public var role: Settable<Role> = .unchanged
    public var active: Settable<Bool> = .unchanged

    public init() {}
}

/// What a server reports about itself.
///
/// Exists so a lagging client can detect version skew and warn clearly rather
/// than failing in a way nobody can diagnose. See ticket 06.
public struct ServerMeta: Decodable, Sendable, Hashable {
    public let serverVersion: String
    public let apiVersions: [String]
    public let instanceName: String
}

/// Requests for the User resource.
///
/// There is no delete: Users are deactivated, because they are referenced as
/// reporter, assignee and comment author permanently. Deactivation is a patch.
public enum UserEndpoints {
    static let base = "/api/v1/users"

    public static func list(page: Pagination = Pagination()) -> HTTPRequest {
        HTTPRequest(method: "GET", path: base, query: pageQuery(page))
    }

    public static func get(_ id: User.ID) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "\(base)/\(id.rawValue.uuidString)")
    }

    /// The authenticated caller. Saves every client resolving its own id first.
    public static func me() -> HTTPRequest {
        HTTPRequest(method: "GET", path: "\(base)/me")
    }

    public static func create(id: User.ID, _ body: UserCreate) throws -> HTTPRequest {
        HTTPRequest(
            method: "PUT", path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(body))
    }

    public static func patch(id: User.ID, _ body: UserPatch) throws -> HTTPRequest {
        HTTPRequest(
            method: "PATCH", path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/merge-patch+json"],
            body: try JSONCoders.encoder.encode(body))
    }
}

/// Instance-level endpoints.
public enum InstanceEndpoints {

    public static func meta() -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/api/v1/meta")
    }

    /// Unversioned and unauthenticated, so a liveness probe keeps working across
    /// an API version change and needs no credentials. See ticket 06.
    public static func health() -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/health")
    }
}
