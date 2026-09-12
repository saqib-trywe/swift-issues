import ClientStore
import Core
import Foundation

/// Whether the stored credential still works.
///
/// Distinct from quarantine on purpose (ticket 07): a rejected token is not a
/// rejected *write*, and the remedy is logging in rather than repairing anything.
/// The pending queue is preserved either way.
public enum AuthenticationState: Sendable, Equatable {
    case valid
    /// The server rejected the token. The queue is intact and will go out once a
    /// new session is established.
    case needsReauthentication
}

/// What sync is doing right now.
public enum SyncProgress: Sendable, Equatable {
    case idle
    case syncing
    /// The server was restored and minted a new epoch, so the replica is being
    /// rebuilt. Presented as normal recovery, never as an error (ticket 09).
    case rebuilding
    case failed(String)
}

/// Everything the five sync surfaces render.
///
/// One value rather than five, because ticket 10's variant C exists precisely so
/// these are written once and *placed* per platform. A platform that assembled its
/// own would be the divergence variant B was rejected to avoid.
public struct SyncStatus: Sendable {
    /// Rejected writes waiting to be repaired or discarded (ADR 0004).
    public var needsAttention: [PendingOperation] = []
    /// Edits lost to a deletion, with the user's text kept (ADR 0005).
    public var lostToDeletion: [SupersededRecord] = []
    /// Unsent edits that will overwrite newer work. Advisory only.
    public var willOverwrite: [StaleEdit] = []
    public var authentication: AuthenticationState = .valid
    public var progress: SyncProgress = .idle
    /// Everything queued, including what is quarantined or held back.
    public var queuedCount: Int = 0

    public init() {}

    /// Whether anything at all is waiting to go out.
    ///
    /// Used by the logout warning, which must state the count and treat proceeding
    /// as explicit destruction (ticket 07).
    public var hasUnsyncedWork: Bool { queuedCount > 0 }

    /// What the Inbox badge counts.
    ///
    /// Only what a person must act on. Queued work needs no attention — it is
    /// going out on its own — and a stale-edit warning is advisory, so counting
    /// either would make the badge permanent and therefore meaningless.
    public var attentionCount: Int {
        needsAttention.count + lostToDeletion.count
            + (authentication == .needsReauthentication ? 1 : 0)
    }

    public var isQuiet: Bool {
        attentionCount == 0 && willOverwrite.isEmpty && progress == .idle
    }
}
