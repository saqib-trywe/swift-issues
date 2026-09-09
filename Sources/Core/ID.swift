import Foundation

/// A typed identifier.
///
/// Every entity is keyed by a UUID, so an untyped `UUID` lets
/// `Issue(projectId: someIssueId)` compile and fail only at runtime. The phantom
/// parameter makes that a build error instead, which matters most where two id
/// types sit side by side — `IssueLabel` holds one of each.
///
/// The phantom leaves no trace on the wire: this encodes as a bare UUID string.
public struct ID<Entity>: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Generates a new time-ordered identifier (UUIDv7). See ADR 0003.
    public init() {
        self.rawValue = UUIDv7.generate()
    }
}

extension ID: Codable {
    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ID: CustomStringConvertible {
    public var description: String { rawValue.uuidString }
}
