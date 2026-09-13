import Core
import Foundation
import Hummingbird
import Synchronization

/// A token bucket per agent session.
///
/// Ticket 12: agent tokens get 60 requests a minute with a burst of 120; human
/// tokens are unlimited. The argument that covers humans — everyone is an
/// identifiable team member who will not hammer the server — fails for an agent,
/// which is identifiable and will hammer the server anyway.
///
/// In memory rather than in the database: a limiter that writes on every request
/// would cost more than the requests it is protecting against, and losing the
/// counters on restart is harmless.
public final class AgentRateLimiter: Sendable {
    /// Sustained rate, per second.
    public static let refillPerSecond = 1.0
    /// The ceiling a burst can reach.
    public static let burst = 120.0

    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
    }

    private let buckets = Mutex<[String: Bucket]>([:])

    public init() {}

    /// Takes one token, or reports how long to wait.
    ///
    /// Returns `nil` when the request may proceed, or the seconds to wait when it
    /// may not — which becomes `Retry-After`.
    public func consume(_ key: String, now: Date = Date()) -> TimeInterval? {
        buckets.withLock { buckets in
            var bucket = buckets[key] ?? Bucket(tokens: Self.burst, lastRefill: now)

            // Refilled lazily rather than on a timer: a bucket nobody is using costs
            // nothing, and there is no sweep to get wrong.
            let elapsed = max(0, now.timeIntervalSince(bucket.lastRefill))
            bucket.tokens = min(Self.burst, bucket.tokens + elapsed * Self.refillPerSecond)
            bucket.lastRefill = now

            guard bucket.tokens >= 1 else {
                buckets[key] = bucket
                // How long until one token exists. Rounded up, so a client that obeys
                // it exactly is not refused again on arrival.
                return max(1, ((1 - bucket.tokens) / Self.refillPerSecond).rounded(.up))
            }

            bucket.tokens -= 1
            buckets[key] = bucket
            return nil
        }
    }

    /// Forgets a session's bucket. Used when a token is revoked.
    public func forget(_ key: String) {
        buckets.withLock { $0[key] = nil }
    }
}

/// Applies the agent limit.
///
/// Sits after authentication because the limit is per session and depends on the
/// token's kind, neither of which is known before then.
public struct AgentRateLimitMiddleware: RouterMiddleware {
    public typealias Context = AppRequestContext

    let limiter: AgentRateLimiter

    public init(limiter: AgentRateLimiter) {
        self.limiter = limiter
    }

    public func handle(
        _ request: Request, context: Context, next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let identity = context.identity
        // Human tokens are unlimited: a person will not saturate the server, and a
        // limit they could hit during ordinary work would be a bug report.
        guard identity.kind != .human else { return try await next(request, context) }

        // Keyed per token: two agents belonging to one person each get their own
        // budget, so a busy one cannot starve the other.
        let key =
            identity.sessionId?.rawValue.uuidString
            ?? identity.userId.rawValue.uuidString
        if let wait = limiter.consume(key) {
            throw ProblemError.throttled(retryAfter: Int(wait))
        }
        return try await next(request, context)
    }
}
