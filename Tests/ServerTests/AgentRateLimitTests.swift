import Core
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import TestSupport
import Testing

@testable import Server

/// Ticket 12's agent limit. The argument that covers humans — everyone is an
/// identifiable team member who will not hammer the server — fails for an agent,
/// which is identifiable and will hammer the server anyway.
@Suite("Agent rate limit")
struct AgentRateLimitTests {

    // MARK: The bucket

    @Test("a fresh bucket allows a full burst")
    func freshBucketAllowsAFullBurst() {
        let limiter = AgentRateLimiter()
        let now = Date()

        for _ in 0..<120 {
            #expect(limiter.consume("agent", now: now) == nil)
        }
        #expect(limiter.consume("agent", now: now) != nil, "the burst was not capped")
    }

    /// A refused request has to say when to come back, or a client can only guess.
    @Test("a refusal reports a wait")
    func refusalReportsAWait() {
        let limiter = AgentRateLimiter()
        let now = Date()
        for _ in 0..<120 { _ = limiter.consume("agent", now: now) }

        let wait = limiter.consume("agent", now: now)
        #expect(wait != nil)
        #expect((wait ?? 0) >= 1, "a wait under a second would be refused again on arrival")
    }

    /// Sustained 60 a minute: after a minute of silence, sixty more are available.
    @Test("the bucket refills over time")
    func bucketRefillsOverTime() {
        let limiter = AgentRateLimiter()
        let start = Date()
        for _ in 0..<120 { _ = limiter.consume("agent", now: start) }
        #expect(limiter.consume("agent", now: start) != nil)

        let later = start.addingTimeInterval(60)
        for _ in 0..<60 {
            #expect(limiter.consume("agent", now: later) == nil)
        }
    }

    /// Refilling must not exceed the burst, or a quiet agent accumulates an
    /// unbounded allowance and the ceiling means nothing.
    @Test("a long silence does not accumulate beyond the burst")
    func longSilenceDoesNotAccumulateBeyondTheBurst() {
        let limiter = AgentRateLimiter()
        let start = Date()
        _ = limiter.consume("agent", now: start)

        let muchLater = start.addingTimeInterval(86_400)
        for _ in 0..<120 {
            #expect(limiter.consume("agent", now: muchLater) == nil)
        }
        #expect(limiter.consume("agent", now: muchLater) != nil)
    }

    /// Two agents belonging to one person each get their own budget, so a busy one
    /// cannot starve the other.
    @Test("buckets are independent")
    func bucketsAreIndependent() {
        let limiter = AgentRateLimiter()
        let now = Date()
        for _ in 0..<120 { _ = limiter.consume("first", now: now) }

        #expect(limiter.consume("first", now: now) != nil)
        #expect(limiter.consume("second", now: now) == nil)
    }

    @Test("forgetting a bucket resets it")
    func forgettingABucketResetsIt() {
        let limiter = AgentRateLimiter()
        let now = Date()
        for _ in 0..<120 { _ = limiter.consume("agent", now: now) }

        limiter.forget("agent")
        #expect(limiter.consume("agent", now: now) == nil)
    }

    // MARK: Through the router

    private func withServer(
        _ body:
            @Sendable @escaping (any TestClientProtocol, AppDatabase, DomainUser) async throws ->
            Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let user = DomainUser.fixture(role: .admin)
        try UserRepository(database: database).save(user)

        let application = Application(
            router: IssuesRouter.build(database: database, rateLimiter: AgentRateLimiter()))
        try await application.test(.router) { client in
            try await body(client, database, user)
        }
    }

    private func call(_ client: any TestClientProtocol, token: String) async throws
        -> HTTPResponse.Status
    {
        try await client.execute(
            uri: "/api/v1/users/me", method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { $0.status }
    }

    /// A person will not saturate the server, and a limit they could hit during
    /// ordinary work would be a bug report.
    @Test("a human token is not limited")
    func humanTokenIsNotLimited() async throws {
        try await withServer { client, database, user in
            let session = try SessionRepository(database: database).create(
                for: user.id, kind: .human, deviceId: nil)

            for _ in 0..<150 {
                #expect(try await call(client, token: session.raw) == .ok)
            }
        }
    }

    @Test("an agent token is limited, and told when to return")
    func agentTokenIsLimited() async throws {
        try await withServer { client, database, user in
            let session = try SessionRepository(database: database).create(
                for: user.id, kind: .agent, deviceId: nil)

            var refused = false
            for _ in 0..<150 where !refused {
                if try await call(client, token: session.raw) == .tooManyRequests {
                    refused = true
                }
            }
            #expect(refused, "an agent was never limited")

            // The header is the mechanism ticket 07 defines, and tool descriptions
            // tell agents to honour it rather than retry through it.
            let retryAfter = try await client.execute(
                uri: "/api/v1/users/me", method: .get,
                headers: [.authorization: "Bearer \(session.raw)"]
            ) { response in
                response.headers[.retryAfter]
            }
            #expect(retryAfter != nil)
        }
    }

    /// A read-only agent is still an agent, and will still loop.
    @Test("a read-only agent token is limited too")
    func readOnlyAgentIsLimitedToo() async throws {
        try await withServer { client, database, user in
            let session = try SessionRepository(database: database).create(
                for: user.id, kind: .agentReadonly, deviceId: nil)

            var refused = false
            for _ in 0..<150 where !refused {
                if try await call(client, token: session.raw) == .tooManyRequests {
                    refused = true
                }
            }
            #expect(refused)
        }
    }

    /// One agent hitting its limit must not refuse another's requests.
    @Test("one agent hitting the limit does not affect another")
    func oneAgentDoesNotAffectAnother() async throws {
        try await withServer { client, database, user in
            let sessions = SessionRepository(database: database)
            let busy = try sessions.create(for: user.id, kind: .agent, deviceId: nil)
            let quiet = try sessions.create(for: user.id, kind: .agent, deviceId: nil)

            var refused = false
            for _ in 0..<150 where !refused {
                if try await call(client, token: busy.raw) == .tooManyRequests { refused = true }
            }
            #expect(refused)
            #expect(try await call(client, token: quiet.raw) == .ok)
        }
    }
}
