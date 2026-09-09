import Foundation

/// A timestamped, user-authored note on an Issue, forming its discussion thread.
public struct Comment: Hashable, Sendable, Codable, Identifiable {
    public typealias ID = Core.ID<Comment>

    public let id: ID
    public let issueId: Issue.ID
    public let authorId: User.ID
    /// Absent once deleted. Deleting a comment clears its text everywhere,
    /// because people delete comments for what is *in* them; the tombstone keeps
    /// only ids and timestamps. Not a security guarantee — backups and
    /// long-offline clients still hold the old text. See ticket 01.
    public var body: String?
    /// Set server-side from the writing token's kind; immutable, so it never
    /// participates in last-write-wins.
    public let via: Via
    public let createdAt: Date
    /// Surfaced as "edited" when later than `createdAt`.
    public var updatedAt: Date
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: ID,
        issueId: Issue.ID,
        authorId: User.ID,
        body: String?,
        via: Via,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.issueId = issueId
        self.authorId = authorId
        self.body = body
        self.via = via
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
