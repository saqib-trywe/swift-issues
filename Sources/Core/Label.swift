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

extension Label {

    /// The colours a label gets when nobody picks one.
    ///
    /// Small and fixed so a tracker looks coherent rather than like a paint
    /// catalogue, and so two labels are rarely near-identical shades.
    public static let palette = [
        "#2D6CDF",  // blue
        "#B5341B",  // rust
        "#1F7A4D",  // green
        "#7A4DB5",  // violet
        "#B58A1F",  // amber
        "#1F7A7A",  // teal
        "#B51F6C",  // magenta
        "#4D5560",  // slate
    ]

    /// Picks a palette entry from the name.
    ///
    /// Derived rather than random so the same name always gets the same colour:
    /// two people creating "bug" offline converge on one id (see `deriveID`), and
    /// they must converge on one colour too, or the label would flicker between
    /// two shades as their writes arrive.
    public static func defaultColor(forName name: String) -> String {
        palette[stableIndex(of: name)]
    }

    /// FNV-1a over the lowercased UTF-8 bytes.
    ///
    /// Swift's own `hashValue` is seeded per process, so using it here would give
    /// a label a different colour every time the binary restarts.
    public static func stableIndex(of name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(palette.count))
    }
}
