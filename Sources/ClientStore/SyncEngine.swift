import Core
import Foundation

/// What a push did.
public struct PushSummary: Sendable, Equatable {
    public var applied: [UUID] = []
    /// Rejected and quarantined, kept for repair.
    public var rejected: [UUID] = []
    /// Valid but lost to a tombstone. The user's text is handed back rather than
    /// queued forever against something that no longer exists.
    public var superseded: [SupersededWrite] = []
    /// Held back because something they depend on is quarantined.
    public var blocked: Int = 0

    public var isEmpty: Bool {
        applied.isEmpty && rejected.isEmpty && superseded.isEmpty
    }
}

/// A write that cannot ever succeed, with what beat it.
///
/// ADR 0005's third outcome exists so this is expressible at all: without it, a
/// write against a deleted entity would be reported as a success while the user's
/// text silently vanished.
public struct SupersededWrite: Sendable, Equatable {
    public let opId: UUID
    public let operation: SyncOperation
    public let current: SyncRecord?

    public static func == (lhs: SupersededWrite, rhs: SupersededWrite) -> Bool {
        lhs.opId == rhs.opId
    }
}

/// What a pull did.
public struct PullSummary: Sendable, Equatable {
    public var changes: Int = 0
    public var pages: Int = 0
    /// True when a superseded epoch forced the replica to be rebuilt.
    public var resynced: Bool = false
    public var watermark: Watermark?
}

/// Drives the offline queue against the server.
///
/// An actor because the UI reads the replica while this writes to it, and the
/// engine's own state — a sync in progress — must not be entered twice.
public actor SyncEngine {
    private let database: ReplicaDatabase
    private let client: APIClient
    private let deviceId: String
    /// A page size, not a total: pull walks until the server says it has no more.
    private let pageSize: Int

    public init(
        database: ReplicaDatabase,
        client: APIClient,
        deviceId: String,
        pageSize: Int = 500
    ) {
        self.database = database
        self.client = client
        self.deviceId = deviceId
        self.pageSize = pageSize
    }

    /// Push then pull.
    ///
    /// In that order deliberately: pushing first means the pull that follows
    /// carries this device's own writes back with the server's timestamps on them,
    /// so the replica ends up holding exactly what the server holds.
    @discardableResult
    public func sync() async throws -> (push: PushSummary, pull: PullSummary) {
        let pushed = try await push()
        let pulled = try await pull()
        return (pushed, pulled)
    }

    // MARK: Push

    /// Sends what is ready and records what became of it.
    public func push(limit: Int = 100) async throws -> PushSummary {
        // Merge first: replaying forty title patches costs forty round trips and
        // gives forty chances to fail, for the same end state.
        try database.coalescePending()

        let ready = try database.readyOperations(limit: limit)
        var summary = PushSummary()
        summary.blocked = try database.blockedOperations().count
        guard !ready.isEmpty else { return summary }

        // Ordered so nothing reaches the server before what it refers to.
        let operations = SyncDependencies.ordered(ready.map(\.operation))
        let byId = Dictionary(uniqueKeysWithValues: operations.map { ($0.opId, $0) })

        let response = try await client.send(
            try SyncEndpoints.push(SyncPush(deviceId: deviceId, operations: operations)),
            expecting: SyncPushResponse.self)

        for result in response.results {
            switch result.outcome {
            case .applied:
                try database.acknowledge(result.opId)
                summary.applied.append(result.opId)

            case .rejected:
                // Kept with its error, never silently dropped (ADR 0004).
                try database.quarantine(result.opId, problem: result.problem)
                summary.rejected.append(result.opId)

            case .superseded:
                // Not quarantined: quarantine means repair and retry, and there is
                // nothing left to retry against. Leaving it pending would produce an
                // operation that fails forever (ticket 05).
                guard let operation = byId[result.opId] else { continue }
                try database.acknowledge(result.opId)
                summary.superseded.append(
                    SupersededWrite(
                        opId: result.opId, operation: operation, current: result.current))
            }
        }

        // The push response's watermark is deliberately **not** adopted. It is the
        // server's position *after* this batch, so taking it would skip everything
        // that happened before — on a first sync, the entire history.
        return summary
    }

    // MARK: Pull

    /// Walks the change stream until the server has nothing more.
    public func pull() async throws -> PullSummary {
        do {
            return try await walk()
        } catch let error as APIError where error.requiresFullResync {
            // The server was restored and minted a new epoch, so this client's
            // position means nothing any more. Base records go; the pending queue
            // stays, because it is unsent user work.
            try database.resetForFullResync()
            var summary = try await walk()
            summary.resynced = true
            return summary
        }
    }

    private func walk() async throws -> PullSummary {
        var summary = PullSummary()
        var since = try database.watermark()

        while true {
            let response = try await client.send(
                SyncEndpoints.pull(since: since, limit: pageSize),
                expecting: SyncPullResponse.self)

            // One transaction per page: a crash mid-page must not leave the
            // watermark ahead of the records it claims to cover, which would skip
            // those changes permanently.
            try database.apply(response.changes, upTo: response.nextWatermark)

            summary.changes += response.changes.count
            summary.pages += 1
            summary.watermark = response.nextWatermark
            since = response.nextWatermark

            guard response.hasMore else { return summary }
        }
    }
}
