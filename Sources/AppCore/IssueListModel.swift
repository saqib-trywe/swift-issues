import ClientStore
import Core
import Foundation
import GRDB
import Observation
import Synchronization

/// The issue list, as the UI sees it.
///
/// `@Observable` over `ValueObservation`, which is the hand-written wrapper
/// ADR 0008 budgeted in place of `@Query` — GRDB is the store, so `@Query` is not
/// available and GRDBQuery is deliberately not a dependency.
///
/// Rows are already overlaid: the server's record with this device's unsent
/// changes applied, and `dirty` naming which fields those are. The UI never tracks
/// dirtiness itself (ticket 10).
@MainActor
@Observable
public final class IssueListModel {
    public private(set) var issues: [Overlaid<Issue>] = []
    public private(set) var status = SyncStatus()
    /// Set when a read fails. Surfaced rather than swallowed: an empty list and a
    /// broken list look identical otherwise.
    public private(set) var failure: String?

    public var projectId: Project.ID? {
        didSet { if projectId != oldValue { reload() } }
    }

    private let database: ReplicaDatabase
    /// Held outside the actor so `deinit` can cancel it: a `deinit` cannot touch
    /// main-actor state, and a leaked observation would keep reading a database the
    /// view has finished with.
    private let observation = ObservationHandle()

    public init(database: ReplicaDatabase, projectId: Project.ID? = nil) {
        self.database = database
        self.projectId = projectId
    }

    deinit { observation.cancel() }

    /// Reads once. Deterministic, which is what tests and a pull-to-refresh both
    /// want.
    public func reload() {
        do {
            issues = try database.issues(in: projectId)
            status = try Self.status(of: database, keeping: status)
            failure = nil
        } catch {
            failure = String(describing: error)
        }
    }

    /// Starts watching the database, delivering a new list on every write.
    ///
    /// Idempotent: calling it twice does not start two observations, because a
    /// view appearing and reappearing is ordinary.
    public func startObserving() {
        guard !observation.isRunning else { return }
        let database = self.database
        let projectId = self.projectId

        observation.start(
            Task { [weak self] in
                // Tracking the whole issue table rather than a specific query: a
                // pending operation changes what the list shows without the issue
                // rows themselves moving, so observing only `issue` would miss an
                // edit the user just made.
                let changes =
                    ValueObservation
                    .tracking { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM issue")
                            ?? 0
                    }
                    .values(in: database.reader)

                do {
                    for try await _ in changes {
                        guard !Task.isCancelled else { return }
                        guard let self else { return }
                        self.apply(database: database, projectId: projectId)
                    }
                } catch {
                    self?.failure = String(describing: error)
                }
            })
    }

    public func stopObserving() {
        observation.cancel()
    }

    private func apply(database: ReplicaDatabase, projectId: Project.ID?) {
        do {
            issues = try database.issues(in: projectId)
            status = try Self.status(of: database, keeping: status)
            failure = nil
        } catch {
            failure = String(describing: error)
        }
    }

    /// Rebuilds the sync surfaces from the database.
    ///
    /// `authentication` and `progress` are carried over rather than re-derived:
    /// they describe what the engine is doing, which no query can see.
    static func status(of database: ReplicaDatabase, keeping previous: SyncStatus) throws
        -> SyncStatus
    {
        var status = SyncStatus()
        status.needsAttention = try database.quarantinedWork()
        status.lostToDeletion = try database.supersededWrites()
        status.willOverwrite = try database.staleEdits()
        status.queuedCount = try database.allOperations().count
        status.authentication = previous.authentication
        status.progress = previous.progress
        return status
    }
}

/// Holds an observation task outside actor isolation.
///
/// Exists only so `deinit` can cancel: a `deinit` cannot reach main-actor state,
/// and an observation that outlives its model keeps reading a database nothing is
/// watching.
final class ObservationHandle: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    var isRunning: Bool { task.withLock { $0 != nil } }

    func start(_ new: Task<Void, Never>) {
        task.withLock { existing in
            existing?.cancel()
            existing = new
        }
    }

    func cancel() {
        task.withLock { existing in
            existing?.cancel()
            existing = nil
        }
    }
}
