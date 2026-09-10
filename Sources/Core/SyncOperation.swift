import Foundation

/// Which entity a sync record or operation refers to.
///
/// `project` and `user` are **pulled but never pushed**: a client's replica needs
/// them to render an issue at all — a project name, an assignee — but they are
/// admin actions performed online through REST. That asymmetry is enforced by
/// `SyncOperation` simply having no cases for them, so a client cannot queue such
/// a write offline.
public enum SyncEntity: String, Codable, Hashable, Sendable {
    case issue
    case comment
    case label
    case issueLabel
    case project
    case user
}

/// What an operation does. Mirrors the REST verbs deliberately.
public enum SyncKind: String, Codable, Hashable, Sendable {
    case put
    case patch
    case delete
}

/// One queued offline write.
///
/// The payloads are the *same* DTOs the REST path sends — `IssueCreate`,
/// `IssuePatch`, `CommentCreate` — which is the concrete form of ADR 0005's
/// anti-drift claim: replay is a translation rather than a re-derivation. If these
/// ever became separate payload types, that decision would have been quietly
/// undone.
///
/// Project and User writes are absent on purpose: they are admin actions performed
/// online through REST, so queueing them would add operation kinds nothing
/// generates.
public enum SyncOperation: Sendable {
    case putIssue(opId: UUID, id: Issue.ID, at: Date, body: IssueCreate)
    case patchIssue(opId: UUID, id: Issue.ID, at: Date, body: IssuePatch)
    case deleteIssue(opId: UUID, id: Issue.ID, at: Date)
    case putComment(opId: UUID, id: Comment.ID, at: Date, body: CommentCreate)
    case patchComment(opId: UUID, id: Comment.ID, at: Date, body: CommentPatch)
    case deleteComment(opId: UUID, id: Comment.ID, at: Date)
    case putLabel(opId: UUID, id: Label.ID, at: Date, body: LabelCreate)
    case patchLabel(opId: UUID, id: Label.ID, at: Date, body: LabelPatch)
    case deleteLabel(opId: UUID, id: Label.ID, at: Date)
    case addLabel(opId: UUID, id: IssueLabel.ID, at: Date, issueId: Issue.ID, labelId: Label.ID)
    case removeLabel(opId: UUID, id: IssueLabel.ID, at: Date)

    /// Distinct from the entity's id, so a retried partially-applied batch dedupes
    /// on the operation rather than the record.
    public var opId: UUID {
        switch self {
        case .putIssue(let o, _, _, _), .patchIssue(let o, _, _, _), .deleteIssue(let o, _, _),
            .putComment(let o, _, _, _), .patchComment(let o, _, _, _),
            .deleteComment(let o, _, _),
            .putLabel(let o, _, _, _), .patchLabel(let o, _, _, _), .deleteLabel(let o, _, _),
            .addLabel(let o, _, _, _, _), .removeLabel(let o, _, _):
            o
        }
    }

    public var entity: SyncEntity {
        switch self {
        case .putIssue, .patchIssue, .deleteIssue: .issue
        case .putComment, .patchComment, .deleteComment: .comment
        case .putLabel, .patchLabel, .deleteLabel: .label
        case .addLabel, .removeLabel: .issueLabel
        }
    }

    public var kind: SyncKind {
        switch self {
        case .putIssue, .putComment, .putLabel, .addLabel: .put
        case .patchIssue, .patchComment, .patchLabel: .patch
        case .deleteIssue, .deleteComment, .deleteLabel, .removeLabel: .delete
        }
    }

    var entityId: UUID {
        switch self {
        case .putIssue(_, let id, _, _), .patchIssue(_, let id, _, _), .deleteIssue(_, let id, _):
            id.rawValue
        case .putComment(_, let id, _, _), .patchComment(_, let id, _, _),
            .deleteComment(_, let id, _):
            id.rawValue
        case .putLabel(_, let id, _, _), .patchLabel(_, let id, _, _), .deleteLabel(_, let id, _):
            id.rawValue
        case .addLabel(_, let id, _, _, _), .removeLabel(_, let id, _):
            id.rawValue
        }
    }

    /// The client's own clock, recorded but **advisory**: conflicts are arbitrated
    /// by the server's receipt timestamp, because client clocks are skewed and
    /// user-adjustable. See ADR 0003.
    public var clientTimestamp: Date {
        switch self {
        case .putIssue(_, _, let at, _), .patchIssue(_, _, let at, _), .deleteIssue(_, _, let at),
            .putComment(_, _, let at, _), .patchComment(_, _, let at, _),
            .deleteComment(_, _, let at),
            .putLabel(_, _, let at, _), .patchLabel(_, _, let at, _), .deleteLabel(_, _, let at),
            .addLabel(_, _, let at, _, _), .removeLabel(_, _, let at):
            at
        }
    }
}

/// The link-record payload for label membership. Sent as records rather than a
/// set, so concurrent adds by two users both survive. See ADR 0003.
struct LabelLinkBody: Codable, Sendable {
    var issueId: Issue.ID
    var labelId: Label.ID
}

extension SyncOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case opId, entity, kind, entityId, clientTimestamp, payload
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opId, forKey: .opId)
        try container.encode(entity, forKey: .entity)
        try container.encode(kind, forKey: .kind)
        try container.encode(entityId, forKey: .entityId)
        try container.encode(clientTimestamp, forKey: .clientTimestamp)

        // A delete has no payload; the key is omitted rather than sent as null.
        switch self {
        case .putIssue(_, _, _, let body): try container.encode(body, forKey: .payload)
        case .patchIssue(_, _, _, let body): try container.encode(body, forKey: .payload)
        case .putComment(_, _, _, let body): try container.encode(body, forKey: .payload)
        case .patchComment(_, _, _, let body): try container.encode(body, forKey: .payload)
        case .putLabel(_, _, _, let body): try container.encode(body, forKey: .payload)
        case .patchLabel(_, _, _, let body): try container.encode(body, forKey: .payload)
        case .addLabel(_, _, _, let issueId, let labelId):
            try container.encode(
                LabelLinkBody(issueId: issueId, labelId: labelId), forKey: .payload)
        case .deleteIssue, .deleteComment, .deleteLabel, .removeLabel:
            break
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let opId = try container.decode(UUID.self, forKey: .opId)
        let entity = try container.decode(SyncEntity.self, forKey: .entity)
        let kind = try container.decode(SyncKind.self, forKey: .kind)
        let rawId = try container.decode(UUID.self, forKey: .entityId)
        let at = try container.decode(Date.self, forKey: .clientTimestamp)

        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            try container.decode(type, forKey: .payload)
        }

        switch (entity, kind) {
        case (.issue, .put):
            self = .putIssue(opId: opId, id: .init(rawId), at: at, body: try payload(IssueCreate.self))
        case (.issue, .patch):
            self = .patchIssue(
                opId: opId, id: .init(rawId), at: at, body: try payload(IssuePatch.self))
        case (.issue, .delete):
            self = .deleteIssue(opId: opId, id: .init(rawId), at: at)
        case (.comment, .put):
            self = .putComment(
                opId: opId, id: .init(rawId), at: at, body: try payload(CommentCreate.self))
        case (.comment, .patch):
            self = .patchComment(
                opId: opId, id: .init(rawId), at: at, body: try payload(CommentPatch.self))
        case (.comment, .delete):
            self = .deleteComment(opId: opId, id: .init(rawId), at: at)
        case (.label, .put):
            self = .putLabel(
                opId: opId, id: .init(rawId), at: at, body: try payload(LabelCreate.self))
        case (.label, .patch):
            self = .patchLabel(
                opId: opId, id: .init(rawId), at: at, body: try payload(LabelPatch.self))
        case (.label, .delete):
            self = .deleteLabel(opId: opId, id: .init(rawId), at: at)
        case (.issueLabel, .put):
            let link = try payload(LabelLinkBody.self)
            self = .addLabel(
                opId: opId, id: .init(rawId), at: at, issueId: link.issueId, labelId: link.labelId)
        case (.issueLabel, .delete):
            self = .removeLabel(opId: opId, id: .init(rawId), at: at)
        case (.issueLabel, .patch):
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "A label link has no mutable fields, so issueLabel/patch is not a valid operation."
                ))
        case (.project, _), (.user, _):
            // Pulled but never pushed: Projects and Users are admin actions
            // performed online through REST, so there is no offline queue entry
            // for them and one arriving here is malformed rather than unsupported.
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "\(entity.rawValue) is replicated but not writable through sync; use the REST API."
                ))
        }
    }
}

/// A batch of queued writes.
///
/// A batch is a round-trip optimisation, not an atomicity boundary: the server
/// applies one transaction per operation, because a single-transaction batch would
/// let one rejected operation roll back the rest. See ticket 08.
public struct SyncPush: Codable, Sendable {
    /// Bound to the session token at login (ticket 07).
    public var deviceId: String
    public var operations: [SyncOperation]

    public init(deviceId: String, operations: [SyncOperation]) {
        self.deviceId = deviceId
        self.operations = operations
    }
}

/// Requests for the sync pair.
public enum SyncEndpoints {

    public static func push(_ body: SyncPush) throws -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: "/api/v1/sync/push",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(body))
    }
}
