import ClientStore
import Core
import Foundation
import Hummingbird
import HummingbirdTesting
import ServerTestSupport
import TestSupport
import Testing

@testable import AppCore
@testable import Server

/// Token management, against the real router. The Mac carries this because there
/// is no web UI, so it is the only interface a token can be minted from.
@MainActor
@Suite("Token list model")
struct TokenListModelTests {

    private static let password = "correct horse battery staple"

    private struct World: Sendable {
        let model: TokenListModel
        let database: AppDatabase
        let owner: Core.User
        let member: Core.User
    }

    private func withWorld(
        asAdmin: Bool = true,
        // `@MainActor`: the model is main-actor isolated, and the test client's
        // closure is not, so the hop has to be explicit.
        _ body: @MainActor @Sendable @escaping (World) async throws -> Void
    ) async throws {
        let database = try AppDatabase.inMemory()
        let users = UserRepository(database: database)
        let owner = Core.User.fixture(
            id: Core.User.ID(), email: "ada@example.com", displayName: "Ada", role: .admin)
        let member = Core.User.fixture(
            id: Core.User.ID(), email: "mel@example.com", displayName: "Mel", role: .member)
        try users.save(owner)
        try users.save(member)
        for user in [owner, member] {
            try users.setPassword(try PasswordHasher.testing.hash(Self.password), for: user.id)
        }

        let actor = asAdmin ? owner : member
        let session = try SessionRepository(database: database).create(
            for: actor.id, kind: .human, deviceId: nil, label: "this Mac")

        let application = Application(router: IssuesRouter.build(database: database))
        try await application.test(.router) { client in
            let token = session.raw
            let transport = RouterTransport(client: client)
            // Built on the main actor, where the model lives.
            let world = await MainActor.run {
                World(
                    model: TokenListModel(
                        client: APIClient(transport: transport, token: { token })),
                    database: database, owner: owner, member: member)
            }
            try await body(world)
        }
    }

    @Test("the current session is listed")
    func currentSessionIsListed() async throws {
        try await withWorld { w in
            await w.model.reload()

            #expect(w.model.failure == nil)
            #expect(w.model.tokens.count == 1)
            #expect(w.model.tokens.first?.label == "this Mac")
        }
    }

    /// A listing is read to decide what to revoke, so it must be safe to show.
    @Test("no token material reaches the model")
    func noTokenMaterialReachesTheModel() async throws {
        try await withWorld { w in
            await w.model.reload()
            let encoded = String(
                decoding: try JSONCoders.encoder.encode(w.model.tokens), as: UTF8.self)

            #expect(!encoded.contains("issues_pat_"))
        }
    }

    /// The raw value exists once. The UI has to show it before it is lost.
    @Test("minting yields a token that works")
    func mintingYieldsAWorkingToken() async throws {
        try await withWorld { w in
            await w.model.mint(password: Self.password, kind: .agent, label: "mcp")

            let minted = try #require(w.model.justMinted)
            #expect(minted.hasPrefix("issues_pat_"))
            #expect(w.model.failure == nil)
            #expect(w.model.tokens.contains { $0.label == "mcp" && $0.kind == .agent })

            // The real proof: it authenticates.
            let authenticated = try SessionRepository(database: w.database).authenticate(minted)
            #expect(authenticated?.kind == .agent)
        }
    }

    /// Leaving it in memory for the life of the window is one more place a secret
    /// can be read from.
    @Test("the minted token is forgotten on request")
    func mintedTokenIsForgottenOnRequest() async throws {
        try await withWorld { w in
            await w.model.mint(password: Self.password, kind: .human, label: "laptop")
            #expect(w.model.justMinted != nil)

            w.model.clearMinted()
            #expect(w.model.justMinted == nil)
        }
    }

    /// Without the password a leaked token could mint replacements, and revoking
    /// the original would leave them working.
    @Test("a wrong password mints nothing, and says why")
    func wrongPasswordMintsNothing() async throws {
        try await withWorld { w in
            await w.model.mint(password: "not it", kind: .human, label: "nope")

            #expect(w.model.justMinted == nil)
            #expect(w.model.failure?.lowercased().contains("password") == true)
        }
    }

    @Test("revoking removes it from the list and stops it working")
    func revokingRemovesItAndStopsIt() async throws {
        try await withWorld { w in
            await w.model.mint(password: Self.password, kind: .agent, label: "doomed")
            let minted = try #require(w.model.justMinted)
            let id = try #require(w.model.tokens.first { $0.label == "doomed" }?.id)

            await w.model.revoke(id)

            #expect(w.model.failure == nil)
            #expect(try SessionRepository(database: w.database).authenticate(minted) == nil)
            // Still listed, marked revoked: a listing is what an Admin reads to work
            // out what happened.
            #expect(w.model.tokens.first { $0.id == id }?.isRevoked == true)
        }
    }

    @Test("revoking something already revoked reports it rather than failing silently")
    func revokingTwiceReportsIt() async throws {
        try await withWorld { w in
            await w.model.mint(password: Self.password, kind: .agent, label: "doomed")
            let id = try #require(w.model.tokens.first { $0.label == "doomed" }?.id)

            await w.model.revoke(id)
            await w.model.revoke(id)

            #expect(w.model.failure?.lowercased().contains("already") == true)
        }
    }

    /// That is how a departing colleague or a leaked token is dealt with.
    @Test("an admin can list somebody else's tokens")
    func adminCanListSomebodyElsesTokens() async throws {
        try await withWorld { w in
            _ = try SessionRepository(database: w.database).create(
                for: w.member.id, kind: .human, deviceId: nil, label: "their laptop")

            w.model.subject = w.member.id
            await w.model.reload()

            #expect(w.model.failure == nil)
            #expect(w.model.tokens.map(\.label) == ["their laptop"])
        }
    }

    @Test("a member cannot list somebody else's tokens")
    func memberCannotListSomebodyElsesTokens() async throws {
        try await withWorld(asAdmin: false) { w in
            w.model.subject = w.owner.id
            await w.model.reload()

            #expect(w.model.failure != nil)
            #expect(w.model.tokens.isEmpty)
        }
    }

    /// Every failure a user can provoke has to read as a sentence, not as an enum
    /// case — this is the only place they learn what went wrong.
    @Test("server failures are described in words", arguments: [
        APIError.unauthenticated(nil),
        APIError.invalidRequest(nil),
        APIError.server(status: 503, problem: nil),
        APIError.rateLimited(retryAfter: nil, problem: nil),
    ])
    func serverFailuresAreDescribedInWords(_ error: APIError) {
        let described = TokenListModel.describe(error)

        #expect(!described.isEmpty)
        #expect(!described.contains("APIError"))
        #expect(described.first?.isUppercase == true)
    }

    /// The server's own detail is preferred when it has one: it was written for
    /// this exact situation.
    @Test("the server's detail is used when it supplies one")
    func serversDetailIsUsedWhenSupplied() {
        let problem = Problem(
            type: "about:blank", title: "Invalid", status: 422,
            detail: "Unknown token kind 'superuser'.")

        #expect(
            TokenListModel.describe(APIError.invalidRequest(problem))
                == "Unknown token kind 'superuser'.")
    }

    /// Ticket 12: the interface has to make clear an agent holds less authority
    /// than its owner. ADR 0007 fixes that profile — an Admin's agent is not an
    /// admin.
    @Test("each kind says what it can do, and the agent kinds say what they cannot")
    func eachKindSaysWhatItCanDo() {
        #expect(!TokenListModel.authorityDescription(.human).isEmpty)

        let agent = TokenListModel.authorityDescription(.agent).lowercased()
        #expect(agent.contains("cannot"))
        #expect(agent.contains("mint") || agent.contains("administer"))

        let readonly = TokenListModel.authorityDescription(.agentReadonly).lowercased()
        #expect(readonly.contains("read-only") || readonly.contains("cannot change"))
    }
}

/// Ticket 07: logout with unsent work is destruction, and must read like it.
@Suite("Logout plan")
struct LogoutPlanTests {

    @Test("signing out with nothing queued is not destructive")
    func signingOutWithNothingQueuedIsNotDestructive() {
        let plan = LogoutPlan(unsyncedCount: 0)

        #expect(!plan.isDestructive)
        #expect(plan.syncFirstTitle == nil)
        #expect(plan.message.lowercased().contains("nothing is lost"))
    }

    /// The count is the whole point: "you have unsaved changes" is not enough to
    /// decide from.
    @Test("the warning states how much would be lost", arguments: [1, 7])
    func warningStatesHowMuchWouldBeLost(_ count: Int) {
        let plan = LogoutPlan(unsyncedCount: count)

        #expect(plan.isDestructive)
        #expect(plan.message.contains("\(count)"))
        #expect(plan.message.lowercased().contains("gone for good"))
    }

    /// The safe path has to be offered, or the only way out is the destructive one.
    @Test("syncing first is offered when there is something to lose")
    func syncingFirstIsOffered() {
        #expect(LogoutPlan(unsyncedCount: 3).syncFirstTitle == "Sync First")
    }

    /// A button labelled "Sign Out" beside a warning about losing work is how
    /// people lose work.
    @Test("the confirming button names the destruction")
    func confirmingButtonNamesTheDestruction() {
        #expect(LogoutPlan(unsyncedCount: 2).confirmTitle.lowercased().contains("discard"))
        #expect(LogoutPlan(unsyncedCount: 0).confirmTitle == "Sign Out")
    }

    /// The dialog's own title has to name the destruction too — the message is
    /// below the fold on a small confirmation.
    @Test("the title says what is at stake")
    func titleSaysWhatIsAtStake() {
        #expect(LogoutPlan(unsyncedCount: 2).title.lowercased().contains("discard"))
        #expect(LogoutPlan(unsyncedCount: 0).title == "Sign out?")
    }

    @Test("one change reads as singular")
    func oneChangeReadsAsSingular() {
        #expect(LogoutPlan(unsyncedCount: 1).message.contains("1 change "))
    }

    @Test("a plan can be built straight from the sync status")
    func planCanBeBuiltFromTheSyncStatus() {
        var status = SyncStatus()
        status.queuedCount = 4

        #expect(LogoutPlan(status: status) == LogoutPlan(unsyncedCount: 4))
    }
}
