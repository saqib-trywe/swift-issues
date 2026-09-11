import Foundation

/// A record of any syncable entity, discriminated by `entity`.
///
/// Shared by push results and pull changes so both speak the same shape.
public enum SyncRecord: Codable, Sendable {
    case issue(Issue)
    case comment(Comment)
    case label(Label)
    case issueLabel(IssueLabel)
    case project(Project)
    case user(User)

    private enum CodingKeys: String, CodingKey { case entity, record }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(SyncEntity.self, forKey: .entity) {
        case .issue: self = .issue(try container.decode(Issue.self, forKey: .record))
        case .comment: self = .comment(try container.decode(Comment.self, forKey: .record))
        case .label: self = .label(try container.decode(Label.self, forKey: .record))
        case .issueLabel: self = .issueLabel(try container.decode(IssueLabel.self, forKey: .record))
        case .project: self = .project(try container.decode(Project.self, forKey: .record))
        case .user: self = .user(try container.decode(User.self, forKey: .record))
        }
    }

    /// The server produces these as well as clients consuming them, so the
    /// discriminator is written back out alongside the record.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .issue(let value):
            try container.encode(SyncEntity.issue, forKey: .entity)
            try container.encode(value, forKey: .record)
        case .comment(let value):
            try container.encode(SyncEntity.comment, forKey: .entity)
            try container.encode(value, forKey: .record)
        case .label(let value):
            try container.encode(SyncEntity.label, forKey: .entity)
            try container.encode(value, forKey: .record)
        case .issueLabel(let value):
            try container.encode(SyncEntity.issueLabel, forKey: .entity)
            try container.encode(value, forKey: .record)
        case .project(let value):
            try container.encode(SyncEntity.project, forKey: .entity)
            try container.encode(value, forKey: .record)
        case .user(let value):
            try container.encode(SyncEntity.user, forKey: .entity)
            try container.encode(value, forKey: .record)
        }
    }
}

/// What became of one pushed operation.
///
/// Three outcomes, not two. Without `superseded` there is nowhere to express "your
/// write was valid but the entity is gone", and it would be reported as a success
/// while the user's text vanished. See ADR 0005.
public enum SyncOutcome: String, Codable, Hashable, Sendable {
    case applied
    /// Quarantined: retrying this payload cannot succeed without user repair.
    case rejected
    /// Lost to a terminal state — the entity is tombstoned.
    case superseded
}

public struct SyncResult: Codable, Sendable {
    public let opId: UUID
    public let outcome: SyncOutcome
    /// The authoritative timestamp, present when the operation applied.
    public let serverTimestamp: Date?
    /// Present when rejected, so the user can repair it.
    public let problem: Problem?
    /// Present when superseded, so the client can show what won and hand the
    /// user's losing text back.
    public let current: SyncRecord?

    public init(
        opId: UUID,
        outcome: SyncOutcome,
        serverTimestamp: Date?,
        problem: Problem?,
        current: SyncRecord?
    ) {
        self.opId = opId
        self.outcome = outcome
        self.serverTimestamp = serverTimestamp
        self.problem = problem
        self.current = current
    }
}

public struct SyncPushResponse: Codable, Sendable {
    /// The server's position after this batch, so the client can pull from
    /// exactly here.
    public let watermark: Watermark
    public let results: [SyncResult]

    public init(watermark: Watermark, results: [SyncResult]) {
        self.watermark = watermark
        self.results = results
    }
}

/// One entry in the change stream.
public struct SyncChange: Decodable, Sendable {
    public let entity: SyncEntity
    public let id: UUID
    /// Tombstones are first-class entries — the only way a delete propagates.
    public let deleted: Bool
    /// Absent for a tombstone.
    public let record: SyncRecord?

    private enum CodingKeys: String, CodingKey { case entity, id, deleted, record }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entity = try container.decode(SyncEntity.self, forKey: .entity)
        id = try container.decode(UUID.self, forKey: .id)
        deleted = try container.decode(Bool.self, forKey: .deleted)

        // The nested record has no `entity` key of its own, so it is rebuilt
        // through SyncRecord using the entity from this entry.
        if container.contains(.record) {
            record =
                switch entity {
                case .issue: .issue(try container.decode(Issue.self, forKey: .record))
                case .comment: .comment(try container.decode(Comment.self, forKey: .record))
                case .label: .label(try container.decode(Label.self, forKey: .record))
                case .issueLabel:
                    .issueLabel(try container.decode(IssueLabel.self, forKey: .record))
                case .project: .project(try container.decode(Project.self, forKey: .record))
                case .user: .user(try container.decode(User.self, forKey: .record))
                }
        } else {
            record = nil
        }
    }
}

public struct SyncPullResponse: Decodable, Sendable {
    public let changes: [SyncChange]
    public let nextWatermark: Watermark
    public let hasMore: Bool
}

extension Problem {
    /// The problem type a server returns when a client presents a watermark from
    /// a superseded epoch — after a restore. Distinct so the client resyncs rather
    /// than treating it as an ordinary conflict. See ticket 09.
    public static let staleEpochType = "https://trywe.co.uk/problems/stale-epoch"
}

extension APIError {
    /// Whether recovering from this error means discarding local base records and
    /// pulling from scratch. Never clears the pending queue: that is unsent user
    /// work. See ticket 08.
    public var requiresFullResync: Bool {
        if case .conflict(let problem) = self {
            return problem?.type == Problem.staleEpochType
        }
        return false
    }
}

extension SyncEndpoints {

    public static func pull(since: Watermark?, limit: Int = 500) -> HTTPRequest {
        var query: [(name: String, value: String)] = []
        // Omitted entirely for a first sync: the same endpoint, just a longer walk.
        if let since { query.append((name: "since", value: since.wireValue)) }
        query.append((name: "limit", value: String(limit)))
        return HTTPRequest(method: "GET", path: "/api/v1/sync/pull", query: query)
    }
}
