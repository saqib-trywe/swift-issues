import Foundation

/// How an Issue is addressed in a URL.
///
/// The API accepts either form (ticket 06). Key addressing exists because humans
/// and agents hold keys, not UUIDs — without it every CLI and MCP call would need
/// a lookup round trip first.
public enum IssueRef: Hashable, Sendable {
    case id(Issue.ID)
    case key(IssueKey)

    var pathComponent: String {
        switch self {
        case .id(let id): id.rawValue.uuidString
        case .key(let key): key.wireValue
        }
    }
}

/// Relationships a caller may ask to have inlined.
///
/// Opt-in, whitelisted, and one level deep: without it a list view is an N+1, and
/// as a default it would bloat every scripted call. See ticket 06.
public enum Expansion: String, Hashable, Sendable, CaseIterable {
    case labels
    case assignee
    case reporter
    case project
}

/// Requests for the Issue resource.
///
/// Pure values, so ticket 06's conventions can be asserted without a network.
public enum IssueEndpoints {

    static let base = "/api/v1/issues"

    public static func get(_ ref: IssueRef, expand: [Expansion] = []) -> HTTPRequest {
        HTTPRequest(
            method: "GET",
            path: "\(base)/\(ref.pathComponent)",
            query: expansionQuery(expand)
        )
    }

    public static func delete(_ id: Issue.ID) -> HTTPRequest {
        HTTPRequest(method: "DELETE", path: "\(base)/\(id.rawValue.uuidString)")
    }

    static func expansionQuery(_ expand: [Expansion]) -> [(name: String, value: String)] {
        guard !expand.isEmpty else { return [] }
        return [(name: "expand", value: expand.map(\.rawValue).joined(separator: ","))]
    }
}
