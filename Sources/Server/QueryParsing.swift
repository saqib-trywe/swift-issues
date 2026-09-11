import Core
import Foundation
import Hummingbird
import HummingbirdCore

/// Parses ticket 06's flat query vocabulary.
///
/// Unrecognised values become `unknown` enum cases rather than being dropped, so a
/// filter for a status this build does not know matches nothing instead of silently
/// widening the result set to everything.
extension IssueFilter {
    init(query: FlatDictionary<Substring, Substring>) {
        self.init(
            projectKey: query["projectKey"[...]].flatMap { ProjectKey(String($0)) },
            statuses: query.commaSeparated("status").map(Status.init(wireValue:)),
            priorities: query.commaSeparated("priority").map(Priority.init(wireValue:)),
            assignee: AssigneeFilter(wireValue: query["assignee"[...]].map(String.init)),
            labels: query.commaSeparated("label"),
            updatedSince: query["updatedSince"[...]].flatMap { JSONCoders.instant(String($0)) },
            query: query["q"[...]].map(String.init)
        )
    }
}

extension AssigneeFilter {
    /// `me` and `none` are tokens, not ids (ticket 06).
    init?(wireValue: String?) {
        switch wireValue {
        case "me": self = .me
        case "none": self = .unassigned
        case let raw?:
            guard let uuid = UUID(uuidString: raw) else { return nil }
            self = .user(User.ID(uuid))
        case nil: return nil
        }
    }
}

extension IssueSort {
    /// A leading `-` means descending.
    init?(wireValue: String?) {
        guard let wireValue, !wireValue.isEmpty else { return nil }
        let descending = wireValue.hasPrefix("-")
        switch descending ? String(wireValue.dropFirst()) : wireValue {
        case "updatedAt": self = .updatedAt(descending: descending)
        case "createdAt": self = .createdAt(descending: descending)
        case "priority": self = .priority(descending: descending)
        case "dueDate": self = .dueDate(descending: descending)
        default: return nil
        }
    }
}

extension Pagination {
    init(query: FlatDictionary<Substring, Substring>) {
        // The limit is clamped by Pagination itself, so an absurd value gives the
        // maximum rather than a failed round trip.
        self.init(
            cursor: query["cursor"[...]].map(String.init),
            limit: query["limit"[...]].flatMap { Int($0) } ?? Pagination.defaultLimit
        )
    }
}

extension FlatDictionary<Substring, Substring> {
    /// Comma-separated values are OR-ed within one parameter (ticket 06).
    func commaSeparated(_ name: String) -> [String] {
        guard let raw = self[name[...]] else { return [] }
        return String(raw).split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}
