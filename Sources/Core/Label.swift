import Foundation

/// A named, coloured tag defined within a Project and applied to its Issues.
///
/// Managed rather than free text, so labels can be renamed and recoloured and do
/// not typo-fork into `backend`/`back-end`/`Backend`. See CONTEXT.md.
public struct Label: Hashable, Sendable, Codable, Identifiable {
    public typealias ID = Core.ID<Label>

    public let id: ID
    public let projectId: Project.ID
    public var name: String
    public var color: String
    public let createdAt: Date
    public var updatedAt: Date
    /// Tombstone. Nothing is hard-deleted: to a syncing client an absent row and
    /// a never-seen row are indistinguishable, so hard deletes resurrect.
    public var deletedAt: Date?

    public init(
        id: ID,
        projectId: Project.ID,
        name: String,
        color: String,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Derives the id two clients will independently agree on for the same label
    /// in the same Project, so concurrent offline creates converge (ADR 0003).
    ///
    /// This is a creation-time device only: after a rename the id no longer
    /// corresponds to the name, which is fine because the id is opaque thereafter.
    public static func deriveID(projectId: Project.ID, name: String) -> ID {
        let normalised = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ID(UUIDv5.generate(namespace: projectId.rawValue, name: normalised))
    }
}
