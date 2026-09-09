/// The short human-facing identifier for an Issue, e.g. `PROJ-142`.
///
/// Permanent: never changed, and never reused even after the Issue is deleted,
/// because reuse would silently repoint every old reference — commit trailers,
/// chat messages, bookmarks — at a different Issue.
///
/// An Issue created offline has *no* key until the server assigns one on first
/// sync, which is why this is modelled as an optional field rather than a string
/// with an empty sentinel. See ADR 0003.
public struct IssueKey: Hashable, Sendable {
    public let projectKey: ProjectKey
    public let number: Int

    /// `nil` unless the number is 1 or greater; the per-Project counter is
    /// monotonic and starts at 1.
    public init?(projectKey: ProjectKey, number: Int) {
        guard number >= 1 else { return nil }
        self.projectKey = projectKey
        self.number = number
    }

    /// `nil` for anything that is not `<PROJECTKEY>-<number>`.
    public init?(_ wireValue: String) {
        let parts = wireValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let projectKey = ProjectKey(String(parts[0])),
            parts[1].utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let number = Int(parts[1])
        else { return nil }
        self.init(projectKey: projectKey, number: number)
    }

    public var wireValue: String { "\(projectKey.wireValue)-\(number)" }
}

extension IssueKey: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = IssueKey(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an Issue Key such as PROJ-142, got \"\(raw)\"."
                )
            )
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
