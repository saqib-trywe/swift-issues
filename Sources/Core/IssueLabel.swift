import Foundation

/// Membership of one Label on one Issue.
///
/// Modelled as its own record rather than a set-valued field on Issue, because a
/// set cannot be resolved by last-write-wins: two users concurrently adding
/// different labels would leave one of them silently discarded. As records, each
/// add and remove converges independently. See ADR 0003.
public struct IssueLabel: Hashable, Sendable, Codable, Identifiable {
    public typealias ID = Core.ID<IssueLabel>

    public let id: ID
    public let issueId: Issue.ID
    public let labelId: Label.ID
    public let createdAt: Date
    public var updatedAt: Date
    /// Removing a label is a tombstone on the link, never a deletion.
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: ID,
        issueId: Issue.ID,
        labelId: Label.ID,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.issueId = issueId
        self.labelId = labelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
