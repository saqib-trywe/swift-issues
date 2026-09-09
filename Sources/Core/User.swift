import Foundation

/// A person with access to the Instance.
///
/// Users are deactivated, never deleted: they are referenced as reporter,
/// assignee and comment author permanently, and a hard delete would orphan all
/// of it. That is why this carries `active` and no `deletedAt`. See CONTEXT.md.
public struct User: Hashable, Sendable, Codable, Identifiable {
    public typealias ID = Core.ID<User>

    public let id: ID
    public var email: String
    public var displayName: String
    public var role: Role
    public var active: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID,
        email: String,
        displayName: String,
        role: Role,
        active: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.role = role
        self.active = active
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
