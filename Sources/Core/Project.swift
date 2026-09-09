import Foundation

/// A named container grouping related Issues; the top-level unit of organisation.
///
/// Retired Projects are archived, never deleted, for the same reason Users are
/// deactivated: their Issues and Issue Keys outlive them. See CONTEXT.md.
public struct Project: Hashable, Sendable, Codable, Identifiable {
    public typealias ID = Core.ID<Project>

    public let id: ID
    /// Immutable after creation: it is baked into every Issue Key.
    public let key: ProjectKey
    public var name: String
    public var description: String
    public var archived: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID,
        key: ProjectKey,
        name: String,
        description: String,
        archived: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.description = description
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
