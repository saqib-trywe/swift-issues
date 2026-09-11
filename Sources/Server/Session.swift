import Core
import CryptoKit
import Foundation
import GRDB

/// What kind of holder a token was issued to.
///
/// An Agent's authority is fixed and narrower than its owner's regardless of that
/// owner's Role, which is why the kind lives on the token rather than being
/// derived from the User. See ADR 0007.
public enum TokenKind: String, Codable, Hashable, Sendable {
    case human
    case agent
    case agentReadonly
}

/// An opaque bearer token.
public struct SessionToken: Sendable {
    /// Exists exactly once, at creation. Never persisted, never recoverable.
    public let raw: String

    /// 256 bits of CSPRNG, prefixed so it is greppable in a leaked config.
    public static func generate() -> SessionToken {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return SessionToken(raw: "issues_pat_" + bytes.map { String(format: "%02x", $0) }.joined())
    }

    /// SHA-256, deliberately *not* a slow KDF.
    ///
    /// A password needs Argon2id because it is low-entropy and guessable. A token
    /// is 256 bits of randomness with nothing to guess, so a KDF here would add
    /// latency to every authenticated request and buy no security at all.
    public static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Who is making a request.
public struct Authenticated: Hashable, Sendable {
    public let userId: User.ID
    public let role: Role
    public let kind: TokenKind
    public let deviceId: String?
}

/// Issues, resolves and revokes sessions.
public struct SessionRepository: Sendable {
    let database: AppDatabase

    /// ADR 0006: 60-day idle expiry, renewed on use. Long on purpose — an
    /// offline-first client can legitimately be offline for weeks, and a short
    /// token would lock the app out of its own sync.
    static let idleExpiry: TimeInterval = 60 * 24 * 60 * 60
    /// Writing last-used on every request would turn every authenticated read
    /// into a write.
    static let lastUsedGranularity: TimeInterval = 60 * 60

    public init(database: AppDatabase) {
        self.database = database
    }

    public func create(
        for userId: User.ID, kind: TokenKind, deviceId: String?, label: String? = nil
    ) throws -> SessionToken {
        let token = SessionToken.generate()
        let now = Date()
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session
                        (token_hash, user_id, device_id, kind, label, created_at, expires_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    SessionToken.hash(token.raw), userId.rawValue.uuidString, deviceId,
                    kind.rawValue, label, now, now.addingTimeInterval(Self.idleExpiry),
                ])
        }
        return token
    }

    /// Resolves a raw token, or `nil` if it is unknown, revoked, expired, or
    /// belongs to a deactivated User.
    ///
    /// Deactivation takes effect at once. ADR 0006 records that this strands any
    /// pending writes on that device — accepted, because the alternative is
    /// letting a deactivated account keep writing.
    public func authenticate(_ raw: String) throws -> Authenticated? {
        let hash = SessionToken.hash(raw)
        return try database.writer.write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT s.user_id, s.kind, s.device_id, s.expires_at, s.last_used_at,
                               u.role, u.active
                        FROM session s JOIN user u ON u.id = s.user_id
                        WHERE s.token_hash = ? AND s.revoked_at IS NULL
                        """,
                    arguments: [hash])
            else { return nil }

            let active: Bool = row["active"]
            guard active else { return nil }

            let now = Date()
            if let expires: Date = row["expires_at"], expires <= now { return nil }

            // Sliding expiry, and coarse last-used so a read stays a read most of
            // the time.
            let lastUsed: Date? = row["last_used_at"]
            if lastUsed == nil || now.timeIntervalSince(lastUsed!) > Self.lastUsedGranularity {
                try db.execute(
                    sql: "UPDATE session SET last_used_at = ?, expires_at = ? WHERE token_hash = ?",
                    arguments: [now, now.addingTimeInterval(Self.idleExpiry), hash])
            }

            guard let userUUID = UUID(uuidString: row["user_id"]) else { return nil }
            return Authenticated(
                userId: User.ID(userUUID),
                role: Role(wireValue: row["role"]),
                kind: TokenKind(rawValue: row["kind"]) ?? .human,
                deviceId: row["device_id"]
            )
        }
    }

    /// Removes sessions that have passed their idle expiry, returning how many went.
    ///
    /// Housekeeping, not enforcement: `authenticate` checks expiry on every request,
    /// so a session that expires between sweeps is still refused. Reaping only stops
    /// the table growing forever. Ticket 04 puts this under ServiceLifecycle rather
    /// than cron or an external scheduler.
    @discardableResult
    public func reapExpired(before now: Date) throws -> Int {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM session WHERE expires_at IS NOT NULL AND expires_at <= ?",
                arguments: [now])
            return db.changesCount
        }
    }

    /// Immediate, which is the whole reason ADR 0006 chose opaque server-side
    /// tokens over JWTs.
    /// Ends every session a user holds.
    ///
    /// Deactivation has to do this. Without it, "deactivate" would mean nothing
    /// until the user's existing tokens idled out — up to sixty days of continued
    /// access for somebody who has just been removed.
    @discardableResult
    public func revokeAll(for userId: User.ID) throws -> Int {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM session WHERE user_id = ?",
                arguments: [userId.rawValue.uuidString])
            return db.changesCount
        }
    }

    public func revoke(_ raw: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE session SET revoked_at = ? WHERE token_hash = ?",
                arguments: [Date(), SessionToken.hash(raw)])
        }
    }
}
