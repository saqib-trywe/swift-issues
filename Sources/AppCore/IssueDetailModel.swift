import ClientStore
import Core
import Foundation
import Observation

/// One issue and its comment thread.
@MainActor
@Observable
public final class IssueDetailModel {
    public private(set) var issue: Overlaid<Issue>?
    public private(set) var comments: [Comment] = []
    public private(set) var labels: [Label] = []
    public private(set) var failure: String?

    /// True when the issue is not in the replica at all — which on a client that
    /// has not finished its first sync is normal, not an error.
    public var isMissing: Bool { issue == nil && failure == nil }

    private let database: ReplicaDatabase
    private let id: Issue.ID

    public init(database: ReplicaDatabase, id: Issue.ID) {
        self.database = database
        self.id = id
    }

    public func reload() {
        do {
            issue = try database.issue(id)
            comments = try database.comments(forIssue: id)
            labels = try database.labels(forIssue: id)
            failure = nil
        } catch {
            failure = String(describing: error)
        }
    }

    /// Which fields carry unsent changes, for marking individual controls.
    public var dirtyFields: Set<IssueField> { issue?.dirty ?? [] }

    /// Whether a field must render read-only.
    ///
    /// Ticket 10: a leniently-decoded `unknown` enum value is read-only in this
    /// client — offering a picker would let the user clobber a value this build
    /// cannot represent, which is exactly what lenient decoding exists to prevent.
    public func isReadOnly(_ field: IssueField) -> Bool {
        guard let issue = issue?.record else { return false }
        switch field {
        case .status:
            if case .unknown = issue.status { return true }
        case .priority:
            if case .unknown = issue.priority { return true }
        default:
            break
        }
        return false
    }
}
