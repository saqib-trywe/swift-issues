import Core
import Foundation
import TestSupport
import Testing

@Suite("Sync push results")
struct SyncResultTests {

    private func decode(_ json: String) throws -> SyncPushResponse {
        try JSONCoders.decoder.decode(SyncPushResponse.self, from: Data(json.utf8))
    }

    /// Push always returns 200 with per-operation results; a rejected operation
    /// must not fail its batch. See ADR 0004 and ADR 0005.
    @Test("a batch reports an outcome per operation, and the current watermark")
    func reportsPerOperationOutcomes() throws {
        let response = try decode(
            """
            {"watermark":"01H8XYZ:4211",
             "results":[
               {"opId":"018F3A9C-0000-7000-8000-0000000000A1","outcome":"applied",
                "serverTimestamp":"2025-09-04T15:33:20.500Z"},
               {"opId":"018F3A9C-0000-7000-8000-0000000000A2","outcome":"applied",
                "serverTimestamp":"2025-09-04T15:33:20.600Z"}]}
            """)

        #expect(response.watermark == Watermark("01H8XYZ:4211"))
        #expect(response.results.count == 2)
        #expect(response.results.allSatisfy { $0.outcome == .applied })
    }

    /// Quarantine: the operation carries the problem so the user can repair it,
    /// and the rest of the batch is unaffected.
    @Test("a rejected operation carries its problem")
    func rejectedCarriesProblem() throws {
        let response = try decode(
            """
            {"watermark":"01H8XYZ:4211",
             "results":[{"opId":"018F3A9C-0000-7000-8000-0000000000A1","outcome":"rejected",
               "problem":{"type":"about:blank","title":"Invalid","status":422,
                 "errors":[{"field":"title","code":"required","message":"A title is required."}]}}]}
            """)

        let result = try #require(response.results.first)
        #expect(result.outcome == .rejected)
        #expect(result.problem?.errors?.first?.code == .required)
    }

    /// The whole reason `superseded` exists: the write was valid but the entity is
    /// tombstoned, so the client shows the user what won and hands their text back
    /// rather than reporting a success that lost silently. See ADR 0005.
    @Test("a superseded operation carries the current server record")
    func supersededCarriesCurrentRecord() throws {
        let response = try decode(
            """
            {"watermark":"01H8XYZ:4211",
             "results":[{"opId":"018F3A9C-0000-7000-8000-0000000000A1","outcome":"superseded",
               "current":{"entity":"issue","record":{
                 "id":"018F3A9C-0000-7000-8000-000000000020","key":"PROJ-142",
                 "projectId":"018F3A9C-0000-7000-8000-000000000002",
                 "title":"Winning title","description":"","status":"todo","priority":"none",
                 "reporterId":"018F3A9C-0000-7000-8000-000000000001",
                 "assigneeId":null,"dueDate":null,"via":"human",
                 "deletedAt":"2025-09-05T09:00:00.000Z",
                 "createdAt":"2025-09-04T15:33:20.123Z",
                 "updatedAt":"2025-09-05T09:00:00.000Z"}}}]}
            """)

        let result = try #require(response.results.first)
        #expect(result.outcome == .superseded)

        guard case .issue(let issue) = try #require(result.current) else {
            Issue.record("expected an issue record")
            return
        }
        #expect(issue.title == "Winning title")
        #expect(issue.isDeleted)
    }
}

@Suite("Sync pull envelope")
struct SyncPullTests {

    /// First sync omits `since` entirely — the same endpoint, just a longer walk.
    @Test("a first sync sends no watermark")
    func firstSyncSendsNoWatermark() {
        let request = SyncEndpoints.pull(since: nil)
        let query = Dictionary(uniqueKeysWithValues: request.query.map { ($0.name, $0.value) })

        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/sync/pull")
        #expect(query["since"] == nil)
    }

    @Test("a resumed sync sends its watermark")
    func resumedSyncSendsWatermark() throws {
        let request = SyncEndpoints.pull(since: try #require(Watermark("01H8XYZ:4210")))
        let query = Dictionary(uniqueKeysWithValues: request.query.map { ($0.name, $0.value) })

        #expect(query["since"] == "01H8XYZ:4210")
    }

    /// One unified stream across entity types, because causal order matters coming
    /// down too and one watermark is one resumable position. See ticket 08.
    @Test("changes arrive as a single stream across entity types")
    func changesAreOneStream() throws {
        let json = """
            {"nextWatermark":"01H8XYZ:4300","hasMore":true,
             "changes":[
               {"entity":"issue","id":"018F3A9C-0000-7000-8000-000000000020","deleted":false,
                "record":{"id":"018F3A9C-0000-7000-8000-000000000020","key":"PROJ-142",
                  "projectId":"018F3A9C-0000-7000-8000-000000000002","title":"A","description":"",
                  "status":"todo","priority":"none",
                  "reporterId":"018F3A9C-0000-7000-8000-000000000001","assigneeId":null,
                  "dueDate":null,"via":"human","deletedAt":null,
                  "createdAt":"2025-09-04T15:33:20.123Z","updatedAt":"2025-09-04T15:33:20.123Z"}},
               {"entity":"issueLabel","id":"018F3A9C-0000-7000-8000-000000000030","deleted":true}]}
            """

        let page = try JSONCoders.decoder.decode(SyncPullResponse.self, from: Data(json.utf8))

        #expect(page.nextWatermark == Watermark("01H8XYZ:4300"))
        #expect(page.hasMore)
        #expect(page.changes.count == 2)
        #expect(page.changes.first?.entity == .issue)
    }

    /// Tombstones are first-class entries with no record — the only way a delete
    /// propagates at all.
    @Test("a tombstone entry carries no record")
    func tombstoneCarriesNoRecord() throws {
        let json = """
            {"nextWatermark":"01H8XYZ:4300","hasMore":false,
             "changes":[{"entity":"issue","id":"018F3A9C-0000-7000-8000-000000000020",
               "deleted":true}]}
            """

        let page = try JSONCoders.decoder.decode(SyncPullResponse.self, from: Data(json.utf8))
        let change = try #require(page.changes.first)

        #expect(change.deleted)
        #expect(change.record == nil)
    }

    /// After a server restore the epoch changes, and a client presenting a stale
    /// one must be told to resync rather than silently receiving nothing forever.
    /// See ticket 09.
    @Test("a stale epoch is recognisable from the problem type")
    func staleEpochIsRecognisable() {
        let body = """
            {"type":"\(Problem.staleEpochType)","title":"Stale epoch","status":409}
            """
        let response = HTTPResponse(status: 409, body: Data(body.utf8))

        let thrown = #expect(throws: APIError.self) {
            try response.decoded(SyncPullResponse.self)
        }

        #expect(thrown?.requiresFullResync == true)
    }

    @Test("an ordinary conflict does not ask for a resync")
    func ordinaryConflictDoesNotResync() {
        let response = HTTPResponse(status: 409, body: Data())

        let thrown = #expect(throws: APIError.self) {
            try response.decoded(SyncPullResponse.self)
        }

        #expect(thrown?.requiresFullResync == false)
    }
}

@Suite("Sync envelope edge cases")
struct SyncEnvelopeEdgeTests {

    @Test("a malformed watermark in a response is rejected, not silently ignored")
    func malformedWatermarkIsRejected() {
        let json = #"{"changes":[],"nextWatermark":"4300","hasMore":false}"#

        #expect(throws: (any Error).self) {
            try JSONCoders.decoder.decode(SyncPullResponse.self, from: Data(json.utf8))
        }
    }

    /// A link record arriving as a live change, not a tombstone — this is how a
    /// label applied on another device reaches this one.
    @Test("a live link-record change carries its record")
    func liveLinkRecordCarriesRecord() throws {
        let json = """
            {"nextWatermark":"01H8XYZ:4301","hasMore":false,
             "changes":[{"entity":"issueLabel","id":"018F3A9C-0000-7000-8000-000000000030",
               "deleted":false,
               "record":{"id":"018F3A9C-0000-7000-8000-000000000030",
                 "issueId":"018F3A9C-0000-7000-8000-000000000020",
                 "labelId":"018F3A9C-0000-7000-8000-000000000003","deletedAt":null,
                 "createdAt":"2025-09-04T15:33:20.123Z",
                 "updatedAt":"2025-09-04T15:33:20.123Z"}}]}
            """

        let page = try JSONCoders.decoder.decode(SyncPullResponse.self, from: Data(json.utf8))

        guard case .issueLabel(let link) = try #require(page.changes.first?.record) else {
            Issue.record("expected an issueLabel record")
            return
        }
        #expect(link.isDeleted == false)
    }

    /// Only a stale epoch means resync. A 401 mid-sync must preserve the queue and
    /// prompt re-login (ADR 0006); treating it as a resync would be destructive.
    @Test(
        "no other error asks for a resync",
        arguments: [APIError.unauthenticated(nil), .gone(nil), .server(status: 503, problem: nil)]
    )
    func otherErrorsDoNotResync(error: APIError) {
        #expect(error.requiresFullResync == false)
    }
}

@Suite("Pull carries every replicated entity")
struct PullEntityCoverageTests {

    /// A client's replica needs Projects and Users to render an issue at all —
    /// a project name, an assignee. They are pulled but never pushed, which is
    /// why SyncOperation has no cases for them.
    @Test("project and user are replicable entities")
    func projectAndUserAreReplicable() {
        #expect(SyncEntity(rawValue: "project") == .project)
        #expect(SyncEntity(rawValue: "user") == .user)
    }

    @Test("a project change carries its record")
    func projectChangeCarriesRecord() throws {
        let json = """
            {"nextWatermark":"01H8XYZ:10","hasMore":false,
             "changes":[{"entity":"project","id":"018F3A9C-0000-7000-8000-000000000002",
               "deleted":false,
               "record":{"id":"018F3A9C-0000-7000-8000-000000000002","key":"PROJ",
                 "name":"Platform","description":"","archived":false,
                 "createdAt":"2025-09-04T15:33:20.123Z",
                 "updatedAt":"2025-09-04T15:33:20.123Z"}}]}
            """

        let page = try JSONCoders.decoder.decode(SyncPullResponse.self, from: Data(json.utf8))

        guard case .project(let project) = try #require(page.changes.first?.record) else {
            Issue.record("expected a project record")
            return
        }
        #expect(project.key == ProjectKey("PROJ"))
    }

    @Test("a user change carries its record")
    func userChangeCarriesRecord() throws {
        let json = """
            {"nextWatermark":"01H8XYZ:11","hasMore":false,
             "changes":[{"entity":"user","id":"018F3A9C-0000-7000-8000-000000000001",
               "deleted":false,
               "record":{"id":"018F3A9C-0000-7000-8000-000000000001","email":"jo@example.com",
                 "displayName":"Jo","role":"member","active":true,
                 "createdAt":"2025-09-04T15:33:20.123Z",
                 "updatedAt":"2025-09-04T15:33:20.123Z"}}]}
            """

        let page = try JSONCoders.decoder.decode(SyncPullResponse.self, from: Data(json.utf8))

        guard case .user(let user) = try #require(page.changes.first?.record) else {
            Issue.record("expected a user record")
            return
        }
        #expect(user.displayName == "Jo")
    }

    /// Neither is pushable: a client cannot queue a project or user write offline,
    /// which stays enforced by SyncOperation having no such cases.
    @Test("push operations still cover only the client-editable entities")
    func pushCoversOnlyEditableEntities() {
        let pushable = Set([SyncEntity.issue, .comment, .label, .issueLabel])

        #expect(pushable.contains(.project) == false)
        #expect(pushable.contains(.user) == false)
    }
}

@Suite("SyncRecord round trips")
struct SyncRecordRoundTripTests {

    /// Every case, because a record kind that cannot survive the wire is an entity
    /// that can never reach a client — and it would fail silently, mid-stream.
    @Test("every record kind round trips with its discriminator")
    func everyRecordKindRoundTrips() throws {
        let projectId = Project.ID()
        let records: [SyncRecord] = [
            .issue(Core.Issue.fixture()),
            .comment(Core.Comment.fixture()),
            .label(Label.fixture(projectId: projectId)),
            .issueLabel(IssueLabel.fixture()),
            .project(Project.fixture()),
            .user(User.fixture()),
        ]

        for record in records {
            let once: Data = try JSONCoders.encoder.encode(record)
            let decoded: SyncRecord = try JSONCoders.decoder.decode(SyncRecord.self, from: once)
            let twice: Data = try JSONCoders.encoder.encode(decoded)
            #expect(once == twice)
        }
    }

    @Test("the discriminator names the entity")
    func discriminatorNamesTheEntity() throws {
        let data: Data = try JSONCoders.encoder.encode(SyncRecord.project(Project.fixture()))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["entity"] as? String == "project")
        #expect(object["record"] is [String: Any])
    }
}
