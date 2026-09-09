import Foundation

public struct CommentCreate: Encodable, Sendable {
    public var issueId: Issue.ID
    public var body: String

    public init(issueId: Issue.ID, body: String) {
        self.issueId = issueId
        self.body = body
    }
}

/// `body` is a Comment's only mutable field, so nothing else is expressible.
public struct CommentPatch: Encodable, Sendable {
    public var body: Settable<String> = .unchanged

    public init() {}
}

/// Requests for the Comment resource.
///
/// The collection is nested under its Issue; the individual resource is
/// top-level, matching how Issues are addressed.
public enum CommentEndpoints {
    static let base = "/api/v1/comments"

    public static func list(issueId: Issue.ID, page: Pagination = Pagination()) -> HTTPRequest {
        HTTPRequest(
            method: "GET",
            path: "\(IssueEndpoints.base)/\(issueId.rawValue.uuidString)/comments",
            query: pageQuery(page))
    }

    public static func get(_ id: Comment.ID) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "\(base)/\(id.rawValue.uuidString)")
    }

    /// PUT at a caller-supplied id, not POST. ADR 0005's reasoning applies here
    /// exactly as it does to Issues: an offline client retrying a create it never
    /// saw a response to must not post the same comment twice.
    public static func create(id: Comment.ID, _ body: CommentCreate) throws -> HTTPRequest {
        HTTPRequest(
            method: "PUT", path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(body))
    }

    public static func patch(id: Comment.ID, _ body: CommentPatch) throws -> HTTPRequest {
        HTTPRequest(
            method: "PATCH", path: "\(base)/\(id.rawValue.uuidString)",
            headers: ["Content-Type": "application/merge-patch+json"],
            body: try JSONCoders.encoder.encode(body))
    }

    public static func delete(_ id: Comment.ID) -> HTTPRequest {
        HTTPRequest(method: "DELETE", path: "\(base)/\(id.rawValue.uuidString)")
    }
}
