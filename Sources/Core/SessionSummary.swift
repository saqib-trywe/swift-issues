import Foundation

/// What kind of holder a token was issued to.
///
/// Lives in Core because clients read it: ticket 07 keeps the kind on the token
/// specifically so an Admin reviewing a list can spot an agent. Leniently decoded
/// like every other wire enum, so adding a kind server-side cannot break a lagging
/// client.
public enum TokenKind: WireEnum {
    case human
    case agent
    case agentReadonly
    case unknown(String)

    public init(wireValue: String) {
        switch wireValue {
        case "human": self = .human
        case "agent": self = .agent
        case "agentReadonly": self = .agentReadonly
        default: self = .unknown(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .human: "human"
        case .agent: "agent"
        case .agentReadonly: "agentReadonly"
        case .unknown(let raw): raw
        }
    }

    /// The kinds this build recognises, for a CLI to name in an error message.
    public static let known: [TokenKind] = [.human, .agent, .agentReadonly]

    /// Whether this token belongs to a person rather than a program.
    ///
    /// `nil` for an unrecognised kind: guessing "human" would widen an unknown
    /// token's authority to the maximum, which is the wrong way to be wrong.
    public var isHuman: Bool? {
        switch self {
        case .human: true
        case .agent, .agentReadonly: false
        case .unknown: nil
        }
    }
}

/// A token, as it appears in a listing.
///
/// Carries no token material at all — not the raw value, which exists once at
/// creation, and not the stored hash. A listing is something an Admin reads to
/// decide what to revoke, so it must be safe to print, log and paste.
public struct SessionSummary: Codable, Sendable, Hashable, Identifiable {
    public typealias ID = Core.ID<SessionSummary>

    public let id: ID
    public let userId: User.ID
    public let kind: TokenKind
    /// What a person called it, so a revocation list means something.
    public let label: String?
    public let deviceId: String?
    public let createdAt: Date
    /// Coarse, to the hour: writing this on every request would turn every
    /// authenticated read into a write.
    public let lastUsedAt: Date?
    public let expiresAt: Date?
    public let revokedAt: Date?

    public var isRevoked: Bool { revokedAt != nil }

    public init(
        id: ID,
        userId: User.ID,
        kind: TokenKind,
        label: String? = nil,
        deviceId: String? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.kind = kind
        self.label = label
        self.deviceId = deviceId
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}

/// What a caller sends to mint a token.
///
/// The password is required even when the caller already holds a valid token.
/// Without it a leaked token could mint children, and revoking the original would
/// leave them working — so the compromise would outlive the revocation.
public struct TokenRequest: Codable, Sendable {
    public var password: String
    public var kind: TokenKind
    public var label: String?
    public var deviceId: String?

    public init(
        password: String, kind: TokenKind = .human, label: String? = nil, deviceId: String? = nil
    ) {
        self.password = password
        self.kind = kind
        self.label = label
        self.deviceId = deviceId
    }
}

/// A newly minted token. The raw value appears here and nowhere else, ever.
public struct TokenIssued: Codable, Sendable {
    public let token: String
    public let session: SessionSummary

    public init(token: String, session: SessionSummary) {
        self.token = token
        self.session = session
    }
}

extension AuthEndpoints {

    static let tokens = "/api/v1/auth/tokens"

    public static func listTokens() -> HTTPRequest {
        HTTPRequest(method: "GET", path: tokens)
    }

    /// `POST`, not `PUT` at a caller-supplied id, unlike every other create here.
    ///
    /// ADR 0005 chose `PUT` so an offline client retrying a create it never saw a
    /// response to cannot write twice. A token is not a synced entity and cannot be
    /// created offline at all — it needs a password round trip — and its response
    /// carries a secret that exists exactly once. A client-chosen id would buy
    /// nothing and let a caller pick the identifier of its own credential.
    public static func createToken(_ body: TokenRequest) throws -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: tokens,
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(body))
    }

    public static func revokeToken(id: SessionSummary.ID) -> HTTPRequest {
        HTTPRequest(method: "DELETE", path: "\(tokens)/\(id.rawValue.uuidString)")
    }
}
