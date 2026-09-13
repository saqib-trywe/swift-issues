import ClientStore
import Core
import Foundation
import Observation

/// Managing personal access tokens.
///
/// The Mac carries this because there is no web UI (ticket 07), so it is the only
/// place a token can be minted, labelled or revoked from an interface.
@MainActor
@Observable
public final class TokenListModel {
    public private(set) var tokens: [SessionSummary] = []
    public private(set) var failure: String?
    public private(set) var isWorking = false

    /// The raw token, held only long enough to be copied. It exists once, here and
    /// nowhere else — the server keeps a hash — so the UI has to show it before it
    /// is lost, and clear it when the sheet closes.
    public private(set) var justMinted: String?

    /// Whose tokens to show. `nil` means the signed-in user's own.
    public var subject: User.ID?

    private let client: APIClient

    public init(client: APIClient, subject: User.ID? = nil) {
        self.client = client
        self.subject = subject
    }

    public func reload() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let request =
                subject.map {
                    HTTPRequest(
                        method: "GET", path: "/api/v1/users/\($0.rawValue.uuidString)/tokens")
                } ?? AuthEndpoints.listTokens()

            tokens = try await client.send(request, expecting: Paginated<SessionSummary>.self).items
            failure = nil
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Mints a token, returning nothing — the value lands in `justMinted`.
    ///
    /// The password is required by the server even though this client is already
    /// authenticated: without it a leaked token could mint replacements, and
    /// revoking the original would leave them working.
    public func mint(password: String, kind: TokenKind, label: String?) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let issued = try await client.send(
                try AuthEndpoints.createToken(
                    TokenRequest(password: password, kind: kind, label: label)),
                expecting: TokenIssued.self)
            justMinted = issued.token
            failure = nil
            await reload()
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Forgets the raw token. Called when the sheet closes, so it is not left in
    /// memory for the life of the window.
    public func clearMinted() {
        justMinted = nil
    }

    public func revoke(_ id: SessionSummary.ID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.send(AuthEndpoints.revokeToken(id: id))
            failure = nil
            await reload()
        } catch {
            failure = Self.describe(error)
        }
    }

    /// What an agent token can do, said plainly.
    ///
    /// Ticket 12 requires the interface to make clear that an agent holds less
    /// authority than its owner — ADR 0007 fixes that profile, and an Admin's agent
    /// is still not an admin.
    public static func authorityDescription(_ kind: TokenKind) -> String {
        switch kind {
        case .human: "Everything you can do."
        case .agent: "Can read and write issues. Cannot administer the instance or mint tokens."
        case .agentReadonly: "Read-only. Cannot change anything."
        case .unknown(let raw): "Unrecognised kind '\(raw)'."
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let error = error as? APIError else { return String(describing: error) }
        return switch error {
        case .forbidden(let problem):
            problem?.detail ?? "That password is not correct."
        case .unauthenticated:
            "Your session has expired. Sign in again."
        case .gone:
            "That token was already revoked."
        case .invalidRequest(let problem):
            problem?.detail ?? "The server refused that."
        default:
            "The server could not be reached."
        }
    }
}

/// What signing out would cost.
///
/// Ticket 07: logging out with a non-empty queue must warn, state how many
/// unsynced changes exist, offer to sync first, and be treated as explicit
/// destruction — because logout clears the local replica, and anything unsent
/// goes with it.
public struct LogoutPlan: Sendable, Equatable {
    public let unsyncedCount: Int

    public init(unsyncedCount: Int) {
        self.unsyncedCount = unsyncedCount
    }

    public init(status: SyncStatus) {
        self.init(unsyncedCount: status.queuedCount)
    }

    /// Whether this needs an explicit confirmation rather than just happening.
    public var isDestructive: Bool { unsyncedCount > 0 }

    public var title: String {
        isDestructive ? "Sign out and discard unsent changes?" : "Sign out?"
    }

    public var message: String {
        guard isDestructive else {
            return "This removes the local copy from this Mac. Nothing is lost — it is all on the server."
        }
        let count =
            unsyncedCount == 1 ? "1 change" : "\(unsyncedCount) changes"
        return
            "\(count) have not reached the server. Signing out removes the local copy, "
            + "and those changes will be gone for good."
    }

    /// Offered ahead of the destructive action, so the safe path is the easy one.
    public var syncFirstTitle: String? { isDestructive ? "Sync First" : nil }

    public var confirmTitle: String { isDestructive ? "Discard and Sign Out" : "Sign Out" }
}
