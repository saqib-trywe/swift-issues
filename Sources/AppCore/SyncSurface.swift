import ClientStore
import Core
import Foundation

/// One thing the sync layer needs to tell the user.
///
/// Ticket 10 calls these five surfaces load-bearing rather than decorative: if any
/// is absent, a sync guarantee is void. They are modelled as data so a platform
/// *places* them rather than writing its own copy — a divergence in wording here
/// becomes a divergence in meaning.
public enum SyncSurface: Sendable, Hashable {
    /// Writes the server rejected, waiting to be repaired or discarded.
    case needsAttention(count: Int)
    /// Edits lost because the record was deleted. The user's text is kept.
    case lostToDeletion(count: Int)
    /// The token no longer works. The queue is intact.
    case needsReauthentication
    /// The replica is being rebuilt after a server restore.
    case rebuilding
    /// Unsent edits that will overwrite newer work. Advisory.
    case willOverwrite(count: Int)
    /// A sync attempt failed outright.
    case failed(String)

    /// How loudly to say it.
    public enum Severity: Sendable, Hashable, Comparable {
        /// Progress, or something advisory. Not a problem.
        case informational
        /// Something the user should look at when convenient.
        case warning
        /// Something is not working until the user acts.
        case blocking
    }

    public var severity: Severity {
        switch self {
        // A rebuild is normal recovery after a restore, not an error (ticket 09).
        case .rebuilding: .informational
        case .willOverwrite: .warning
        case .lostToDeletion: .warning
        case .needsAttention: .warning
        case .needsReauthentication: .blocking
        case .failed: .blocking
        }
    }

    public var title: String {
        switch self {
        case .needsAttention(let count):
            count == 1 ? "1 change needs attention" : "\(count) changes need attention"
        case .lostToDeletion(let count):
            count == 1 ? "1 edit was lost to a deletion" : "\(count) edits were lost to deletions"
        case .needsReauthentication:
            "Sign in again"
        case .rebuilding:
            "Rebuilding from the server"
        case .willOverwrite(let count):
            count == 1
                ? "1 unsent edit will overwrite newer work"
                : "\(count) unsent edits will overwrite newer work"
        case .failed:
            "Couldn't sync"
        }
    }

    public var detail: String {
        switch self {
        case .needsAttention:
            "The server refused these. Your text is kept — repair or discard each one."

        // Ticket 10 is explicit that this means superseded-*by-deletion* only.
        // "Someone else edited this field" cannot happen under receipt-time
        // last-write-wins, so saying it would describe a situation the system does
        // not produce.
        case .lostToDeletion:
            "The issue was deleted, so there is nothing to send these to. Your text is here to copy out."

        // Distinct from quarantine (ticket 07): nothing is wrong with the writes,
        // and saying so stops people hunting for a mistake they did not make.
        case .needsReauthentication:
            "Your session expired. Nothing has been lost — your unsent changes go out once you sign in."

        case .rebuilding:
            "The server was restored, so the local copy is being rebuilt. Your unsent changes are safe."

        case .willOverwrite:
            "These were made before somebody else's changes arrived. Sending them will replace that newer work."

        case .failed(let reason):
            reason
        }
    }
}

extension SyncStatus {

    /// Every surface worth showing, most urgent first.
    ///
    /// Assembled here rather than per platform: ticket 10 rejected variant B
    /// precisely because these would then be designed twice, and these are the
    /// surfaces where a subtle divergence is a correctness problem rather than a
    /// cosmetic one.
    public var surfaces: [SyncSurface] {
        var surfaces: [SyncSurface] = []

        if authentication == .needsReauthentication { surfaces.append(.needsReauthentication) }
        if case .failed(let reason) = progress { surfaces.append(.failed(reason)) }
        if !needsAttention.isEmpty { surfaces.append(.needsAttention(count: needsAttention.count)) }
        if !lostToDeletion.isEmpty {
            surfaces.append(.lostToDeletion(count: lostToDeletion.count))
        }
        if !willOverwrite.isEmpty { surfaces.append(.willOverwrite(count: willOverwrite.count)) }
        if progress == .rebuilding { surfaces.append(.rebuilding) }

        return surfaces.sorted { $0.severity > $1.severity }
    }

    /// What to say about ordinary progress.
    ///
    /// Deliberately describes **state, not freshness**. iOS background refresh has
    /// no timing guarantee, so "updated 2 minutes ago" becomes a lie the moment a
    /// refresh is missed — and the user cannot tell the difference.
    public var progressDescription: String {
        // With no working credential nothing has synced, so "up to date" would be a
        // claim the client cannot make. Found by looking at the running app: it said
        // exactly that beside a "sign in again" banner.
        if authentication == .needsReauthentication {
            return queuedCount == 0
                ? "Not syncing — signed out"
                : "Not syncing — \(queuedCount) change\(queuedCount == 1 ? "" : "s") waiting"
        }

        switch progress {
        case .idle:
            return queuedCount == 0
                ? "Up to date with the server"
                : (queuedCount == 1
                    ? "1 change waiting to send" : "\(queuedCount) changes waiting to send")
        case .syncing: return "Syncing…"
        case .rebuilding: return "Rebuilding…"
        case .failed: return "Not synced"
        }
    }
}
