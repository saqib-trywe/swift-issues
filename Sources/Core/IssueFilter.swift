import Foundation

/// Who an Issue is assigned to, as a filter.
///
/// `me` and `none` are tokens rather than ids: ticket 06 added them for CLI and
/// MCP ergonomics, since the alternative is resolving your own user id first.
public enum AssigneeFilter: Hashable, Sendable {
    case me
    case unassigned
    case user(User.ID)

    var wireValue: String {
        switch self {
        case .me: "me"
        case .unassigned: "none"
        case .user(let id): id.rawValue.uuidString
        }
    }
}

/// Criteria for listing Issues.
///
/// Flat parameters over a fixed vocabulary rather than a query language: a DSL is
/// a parser and an injection surface. The cost, accepted in ticket 06, is no OR
/// across different fields and no negation.
///
/// Values within one field are **OR**-ed; different fields are **AND**-ed.
public struct IssueFilter: Hashable, Sendable {
    public var projectKey: ProjectKey?
    public var statuses: [Status]
    public var priorities: [Priority]
    public var assignee: AssigneeFilter?
    /// Label *names*, as a caller types them.
    public var labels: [String]
    public var updatedSince: Date?
    /// Substring match over title and description in v1.
    public var query: String?

    public init(
        projectKey: ProjectKey? = nil,
        statuses: [Status] = [],
        priorities: [Priority] = [],
        assignee: AssigneeFilter? = nil,
        labels: [String] = [],
        updatedSince: Date? = nil,
        query: String? = nil
    ) {
        self.projectKey = projectKey
        self.statuses = statuses
        self.priorities = priorities
        self.assignee = assignee
        self.labels = labels
        self.updatedSince = updatedSince
        self.query = query
    }
}

/// How a list is ordered. Descending is expressed on the wire with a leading `-`.
public enum IssueSort: Hashable, Sendable {
    case updatedAt(descending: Bool)
    case createdAt(descending: Bool)
    case priority(descending: Bool)
    case dueDate(descending: Bool)

    var wireValue: String {
        let (field, descending): (String, Bool) =
            switch self {
            case .updatedAt(let d): ("updatedAt", d)
            case .createdAt(let d): ("createdAt", d)
            case .priority(let d): ("priority", d)
            case .dueDate(let d): ("dueDate", d)
            }
        return descending ? "-\(field)" : field
    }
}

/// A page request.
///
/// Cursor-based, because offset paging silently skips and duplicates rows while
/// records are being created and deleted mid-scan. Cursors are opaque and only
/// ever come back from a previous response. See ticket 06.
public struct Pagination: Hashable, Sendable {
    public static let defaultLimit = 50
    public static let maximumLimit = 200

    public var cursor: String?
    public var limit: Int

    public init(cursor: String? = nil, limit: Int = Pagination.defaultLimit) {
        self.cursor = cursor
        // Clamped rather than rejected: a caller asking for more than the server
        // allows should get the maximum, not a failed round trip.
        self.limit = min(max(limit, 1), Pagination.maximumLimit)
    }
}

/// A page of results.
///
/// `Codable` rather than decode-only: the server produces these as well as
/// clients consuming them.
public struct Paginated<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    /// `nil` on the last page.
    public let nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}
