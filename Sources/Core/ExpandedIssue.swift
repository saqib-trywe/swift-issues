import Foundation

/// An Issue with requested relationships resolved alongside it.
///
/// The expansions sit **beside** the ids they resolve — `assigneeId` and
/// `assignee` both appear — so the shape is strictly additive: anything decoding a
/// plain `Issue` keeps working whether or not expansion was asked for. That is what
/// lets `expand` be added to a live API without a version change.
///
/// One level deep and no recursion, per ticket 06: an expanded assignee does not
/// itself carry expansions.
public struct ExpandedIssue: Sendable {
    public let issue: Issue
    /// `nil` when not requested. An empty array means requested and none found,
    /// which is a different thing.
    public let labels: [Label]?
    public let assignee: User?
    public let reporter: User?
    public let project: Project?

    public init(
        issue: Issue,
        labels: [Label]? = nil,
        assignee: User? = nil,
        reporter: User? = nil,
        project: Project? = nil
    ) {
        self.issue = issue
        self.labels = labels
        self.assignee = assignee
        self.reporter = reporter
        self.project = project
    }
}

extension ExpandedIssue: Codable {
    private enum CodingKeys: String, CodingKey {
        case labels, assignee, reporter, project
    }

    public init(from decoder: any Decoder) throws {
        // The issue's own fields are read from the same container, flat.
        issue = try Issue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labels = try container.decodeIfPresent([Label].self, forKey: .labels)
        assignee = try container.decodeIfPresent(User.self, forKey: .assignee)
        reporter = try container.decodeIfPresent(User.self, forKey: .reporter)
        project = try container.decodeIfPresent(Project.self, forKey: .project)
    }

    public func encode(to encoder: any Encoder) throws {
        // Written into the same keyed container, so the result is one flat object
        // rather than a nested one.
        try issue.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(labels, forKey: .labels)
        try container.encodeIfPresent(assignee, forKey: .assignee)
        try container.encodeIfPresent(reporter, forKey: .reporter)
        try container.encodeIfPresent(project, forKey: .project)
    }
}

extension Expansion {
    /// Parses a comma-separated `expand` parameter.
    ///
    /// An unrecognised value is **refused** rather than ignored, matching how this
    /// project treats unknown config keys and mistyped filter values: silently
    /// expanding nothing would look identical to a server that does not support the
    /// relationship, and the caller would have no way to tell.
    public static func parse(_ raw: String) throws -> [Expansion] {
        try raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { value in
                guard let expansion = Expansion(rawValue: value) else {
                    throw ExpansionError.unknown(value)
                }
                return expansion
            }
    }
}

public enum ExpansionError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknown(String)

    public var description: String {
        switch self {
        case .unknown(let value):
            "Unknown expansion '\(value)'. Known expansions: "
                + Expansion.allCases.map(\.rawValue).sorted().joined(separator: ", ") + "."
        }
    }
}
