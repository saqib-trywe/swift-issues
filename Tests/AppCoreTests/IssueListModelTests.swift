import ClientStore
import Core
import Foundation
import TestSupport
import Testing

@testable import AppCore

typealias DomainIssue = Core.Issue

/// The shared behaviour layer. Ticket 10's variant C writes these once and places
/// them per platform, so a bug here is a bug on every platform at once.
@MainActor
@Suite("Issue list model")
struct IssueListModelTests {

    private let projectId = Project.ID()
    private let watermark = Watermark(epoch: "e1", sequence: 1)!

    private func store(
        _ database: ReplicaDatabase, _ issues: [DomainIssue]
    ) throws {
        try database.apply(
            issues.map {
                SyncChange(entity: .issue, id: $0.id.rawValue, deleted: false, record: .issue($0))
            },
            upTo: watermark)
    }

    private func issue(_ title: String) -> DomainIssue {
        DomainIssue.fixture(key: nil, projectId: projectId, title: title)
    }

    @Test("reloading reads the replica")
    func reloadingReadsTheReplica() throws {
        let database = try ReplicaDatabase.inMemory()
        try store(database, [issue("First"), issue("Second")])

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        #expect(model.issues.count == 2)
        #expect(model.failure == nil)
    }

    /// Rows arrive already overlaid, so the UI never has to combine the base
    /// record with the queue itself.
    @Test("rows carry unsent changes and say which fields are dirty")
    func rowsCarryUnsentChanges() throws {
        let database = try ReplicaDatabase.inMemory()
        let target = issue("Server title")
        try store(database, [target])

        var patch = IssuePatch()
        patch.title = .set("My edit")
        try database.enqueue(.patchIssue(opId: UUID(), id: target.id, at: Date(), body: patch))

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        let row = try #require(model.issues.first)
        #expect(row.record.title == "My edit")
        #expect(row.dirty == [.title])
    }

    @Test("changing the project reloads for it")
    func changingTheProjectReloads() throws {
        let database = try ReplicaDatabase.inMemory()
        let other = Project.ID()
        try store(database, [issue("Mine")])
        try database.apply(
            [
                SyncChange(
                    entity: .issue, id: UUID(), deleted: false,
                    record: .issue(DomainIssue.fixture(key: nil, projectId: other, title: "Theirs")))
            ], upTo: watermark)

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()
        #expect(model.issues.count == 1)

        model.projectId = other
        #expect(model.issues.first?.record.title == "Theirs")
    }

    /// An empty list and a broken list look identical unless the failure is
    /// surfaced.
    @Test("a read failure is reported rather than swallowed")
    func readFailureIsReported() throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()
        #expect(model.failure == nil)
        #expect(model.issues.isEmpty)
    }

    // MARK: The five sync surfaces

    @Test("quarantined work appears as needing attention")
    func quarantinedWorkNeedsAttention() throws {
        let database = try ReplicaDatabase.inMemory()
        let target = issue("Server title")
        try store(database, [target])

        var patch = IssuePatch()
        patch.title = .set("Rejected")
        let operation = SyncOperation.patchIssue(
            opId: UUID(), id: target.id, at: Date(), body: patch)
        try database.enqueue(operation)
        try database.quarantine(
            operation.opId,
            problem: Problem(
                type: "about:blank", title: "Invalid", status: 422, detail: "Too long."))

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        #expect(model.status.needsAttention.count == 1)
        #expect(model.status.needsAttention.first?.problem?.detail == "Too long.")
    }

    @Test("work lost to a deletion is surfaced with the user's text")
    func workLostToADeletionIsSurfaced() throws {
        let database = try ReplicaDatabase.inMemory()
        var patch = IssuePatch()
        patch.title = .set("Two hours of writing")
        try database.recordSuperseded(
            .patchIssue(opId: UUID(), id: DomainIssue.ID(), at: Date(), body: patch),
            current: nil, reason: .deletedElsewhere)

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        #expect(model.status.lostToDeletion.count == 1)
    }

    /// The only place a user learns their offline edit will overwrite newer work.
    @Test("an edit that would overwrite newer work is flagged")
    func editThatWouldOverwriteIsFlagged() throws {
        let database = try ReplicaDatabase.inMemory()
        var target = issue("Server title")
        target.updatedAt = Date()
        try store(database, [target])

        var patch = IssuePatch()
        patch.title = .set("Written on a plane")
        try database.enqueue(
            .patchIssue(
                opId: UUID(), id: target.id, at: Date().addingTimeInterval(-86_400), body: patch))

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        #expect(model.status.willOverwrite.count == 1)
        #expect(model.status.willOverwrite.first?.fields == [.title])
    }

    /// Ticket 07 keeps these apart: a rejected token is not a rejected write, and
    /// the remedy is logging in rather than repairing anything.
    @Test("needing re-authentication is separate from quarantine")
    func needingReauthenticationIsSeparate() {
        var status = SyncStatus()
        status.authentication = .needsReauthentication

        #expect(status.needsAttention.isEmpty)
        #expect(status.attentionCount == 1)
    }

    /// A full resync after a restore is normal recovery, not a failure.
    @Test("rebuilding is a progress state, not a failure")
    func rebuildingIsProgressNotFailure() {
        var status = SyncStatus()
        status.progress = .rebuilding

        #expect(status.progress != .failed("rebuilding"))
        #expect(!status.isQuiet)
        #expect(status.attentionCount == 0, "a resync in progress is not something to act on")
    }

    /// Ticket 07: logout with a non-empty queue must state the count and be treated
    /// as explicit destruction.
    @Test("unsynced work is counted for the logout warning")
    func unsyncedWorkIsCountedForTheLogoutWarning() throws {
        let database = try ReplicaDatabase.inMemory()
        for index in 0..<3 {
            try database.enqueue(
                .putIssue(
                    opId: UUID(), id: DomainIssue.ID(), at: Date(),
                    body: IssueCreate(projectId: projectId, title: "Unsent \(index)")))
        }

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        #expect(model.status.queuedCount == 3)
        #expect(model.status.hasUnsyncedWork)
    }

    /// A badge that is always lit is a badge nobody reads.
    @Test("ordinary queued work does not light the badge")
    func ordinaryQueuedWorkDoesNotLightTheBadge() throws {
        let database = try ReplicaDatabase.inMemory()
        try database.enqueue(
            .putIssue(
                opId: UUID(), id: DomainIssue.ID(), at: Date(),
                body: IssueCreate(projectId: projectId, title: "Going out fine")))

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        #expect(model.status.hasUnsyncedWork)
        #expect(model.status.attentionCount == 0)
    }

    /// An advisory warning is not something to act on either, or the badge never
    /// clears while an old edit sits in the queue.
    @Test("an advisory warning does not light the badge")
    func advisoryWarningDoesNotLightTheBadge() {
        var status = SyncStatus()
        status.willOverwrite = [
            StaleEdit(
                operation: .patchIssue(
                    opId: UUID(), id: DomainIssue.ID(), at: Date(), body: IssuePatch()),
                fields: [.title], editedAt: Date(), serverChangedAt: Date())
        ]

        #expect(status.attentionCount == 0)
        #expect(!status.isQuiet)
    }

    @Test("a quiet instance is quiet")
    func quietInstanceIsQuiet() throws {
        let database = try ReplicaDatabase.inMemory()
        try store(database, [issue("Nothing pending")])

        let model = IssueListModel(database: database, projectId: projectId)
        model.reload()

        #expect(model.status.isQuiet)
        #expect(!model.status.hasUnsyncedWork)
    }

    // MARK: Observation

    /// The hand-written wrapper ADR 0008 budgeted in place of `@Query`.
    @Test("observing delivers a new list when the database changes")
    func observingDeliversANewList() async throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueListModel(database: database, projectId: projectId)
        model.startObserving()

        try store(database, [issue("Arrived later")])

        // Bounded wait rather than a fixed sleep: fast when it works, and it fails
        // rather than hanging when it does not.
        var attempts = 0
        while model.issues.isEmpty && attempts < 100 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }

        #expect(model.issues.count == 1)
        #expect(model.issues.first?.record.title == "Arrived later")
        model.stopObserving()
    }

    /// A view appearing and reappearing is ordinary, and must not start a second
    /// observation each time.
    @Test("starting twice does not start two observations")
    func startingTwiceDoesNotStartTwo() async throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueListModel(database: database, projectId: projectId)

        model.startObserving()
        model.startObserving()
        model.stopObserving()

        // Stopping once leaves nothing running, which is only true if starting
        // twice created one observation.
        model.startObserving()
        model.stopObserving()
    }
}

@MainActor
@Suite("Sync state on the model")
struct ModelSyncStateTests {

    /// No query can see whether a sync is in flight, so the engine writes it on.
    @Test("progress is set from outside and survives a reload")
    func progressIsSetFromOutsideAndSurvivesAReload() throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueListModel(database: database)

        model.setProgress(.syncing)
        #expect(model.status.progress == .syncing)

        // A reload re-derives the queue-backed surfaces but must not discard what
        // only the engine knows.
        model.reload()
        #expect(model.status.progress == .syncing)
    }

    @Test("authentication state is set from outside and survives a reload")
    func authenticationSurvivesAReload() throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueListModel(database: database)

        model.setAuthentication(.needsReauthentication)
        model.reload()

        #expect(model.status.authentication == .needsReauthentication)
        #expect(model.status.surfaces.contains(.needsReauthentication))
    }

    /// The bug found by looking at the running app, now guarded at the model.
    @Test("a signed-out model does not claim to be up to date")
    func signedOutModelDoesNotClaimToBeUpToDate() throws {
        let database = try ReplicaDatabase.inMemory()
        let model = IssueListModel(database: database)

        model.setAuthentication(.needsReauthentication)
        model.reload()

        #expect(!model.status.progressDescription.lowercased().contains("up to date"))
    }
}
