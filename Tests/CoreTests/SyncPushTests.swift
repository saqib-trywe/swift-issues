import Core
import Foundation
import TestSupport
import Testing

@Suite("Sync push envelope")
struct SyncPushTests {

    private let opId = UUID(uuidString: "018F3A9C-0000-7000-8000-0000000000A1")!
    private let issueId = Core.Issue.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000020")!)
    private let projectId = Project.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000002")!)
    private let at = Date(timeIntervalSince1970: 1_757_000_000.123)

    private func encoded(_ operation: SyncOperation) throws -> [String: Any] {
        let data = try JSONCoders.encoder.encode(operation)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The opId is distinct from the entityId so a retried, partially-applied
    /// batch dedupes on the operation rather than the record. See ticket 06.
    @Test("an operation carries its own id alongside the entity's")
    func operationCarriesItsOwnID() throws {
        let object = try encoded(
            .putIssue(
                opId: opId, id: issueId, at: at,
                body: IssueCreate(projectId: projectId, title: "New")))

        #expect(object["opId"] as? String == "018F3A9C-0000-7000-8000-0000000000A1")
        #expect(object["entityId"] as? String == "018F3A9C-0000-7000-8000-000000000020")
        #expect(object["entity"] as? String == "issue")
        #expect(object["kind"] as? String == "put")
        #expect(object["clientTimestamp"] as? String == "2025-09-04T15:33:20.123Z")
    }

    /// The payoff of ADR 0005's shared DTOs: a queued patch is the same Merge
    /// Patch body the REST path sends, so replay is a translation rather than a
    /// re-derivation — and untouched fields stay absent.
    @Test("a queued patch reuses the REST body and omits untouched fields")
    func queuedPatchReusesRESTBody() throws {
        var patch = IssuePatch()
        patch.status = .set(.done)

        let object = try encoded(.patchIssue(opId: opId, id: issueId, at: at, body: patch))
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(object["kind"] as? String == "patch")
        #expect(payload.keys.sorted() == ["status"])
        #expect(payload["status"] as? String == "done")
    }

    @Test("a delete carries no payload")
    func deleteCarriesNoPayload() throws {
        let object = try encoded(.deleteIssue(opId: opId, id: issueId, at: at))

        #expect(object["kind"] as? String == "delete")
        #expect(object["payload"] == nil)
    }

    @Test("label membership is queued as link records, not a set")
    func labelMembershipIsLinkRecords() throws {
        let linkId = IssueLabel.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000030")!)
        let labelId = Label.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000003")!)

        let object = try encoded(
            .addLabel(opId: opId, id: linkId, at: at, issueId: issueId, labelId: labelId))

        #expect(object["entity"] as? String == "issueLabel")
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["labelId"] as? String == "018F3A9C-0000-7000-8000-000000000003")
    }

    @Test("operations survive a round trip")
    func operationsRoundTrip() throws {
        var patch = IssuePatch()
        patch.title = .set("Renamed")
        let original = SyncOperation.patchIssue(opId: opId, id: issueId, at: at, body: patch)

        let once = try JSONCoders.encoder.encode(original)
        let decoded = try JSONCoders.decoder.decode(SyncOperation.self, from: once)
        let twice = try JSONCoders.encoder.encode(decoded)

        #expect(once == twice)
        #expect(decoded.opId == opId)
    }

    @Test("a push batch carries the device it came from")
    func batchCarriesDevice() throws {
        let batch = SyncPush(
            deviceId: "mac-studio-1",
            operations: [.deleteIssue(opId: opId, id: issueId, at: at)])

        let data = try JSONCoders.encoder.encode(batch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["deviceId"] as? String == "mac-studio-1")
        #expect((object["operations"] as? [Any])?.count == 1)
    }

    @Test("push posts to the sync endpoint")
    func pushEndpoint() throws {
        let request = try SyncEndpoints.push(
            SyncPush(deviceId: "d", operations: []))

        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/sync/push")
    }
}

@Suite("Sync operation coverage")
struct SyncOperationRoundTripTests {

    private static let opId = UUID(uuidString: "018F3A9C-0000-7000-8000-0000000000A1")!
    private static let at = Date(timeIntervalSince1970: 1_757_000_000.123)
    private static let issueId = Core.Issue.ID(
        UUID(uuidString: "018F3A9C-0000-7000-8000-000000000020")!)
    private static let projectId = Project.ID(
        UUID(uuidString: "018F3A9C-0000-7000-8000-000000000002")!)
    private static let commentId = Core.Comment.ID(
        UUID(uuidString: "018F3A9C-0000-7000-8000-000000000010")!)
    private static let labelId = Label.ID(UUID(uuidString: "018F3A9C-0000-7000-8000-000000000003")!)
    private static let linkId = IssueLabel.ID(
        UUID(uuidString: "018F3A9C-0000-7000-8000-000000000030")!)

    /// Every operation kind, because a kind that cannot survive the wire is a
    /// write that can never leave a device — and it would fail silently, in the
    /// queue, on someone's laptop.
    static let allKinds: [(String, SyncOperation)] = {
        var issuePatch = IssuePatch()
        issuePatch.title = .set("Renamed")
        var commentPatch = CommentPatch()
        commentPatch.body = .set("Edited")
        var labelPatch = LabelPatch()
        labelPatch.color = .set("#0E8A6B")

        return [
            (
                "putIssue",
                .putIssue(
                    opId: opId, id: issueId, at: at,
                    body: IssueCreate(projectId: projectId, title: "New"))
            ),
            ("patchIssue", .patchIssue(opId: opId, id: issueId, at: at, body: issuePatch)),
            ("deleteIssue", .deleteIssue(opId: opId, id: issueId, at: at)),
            (
                "putComment",
                .putComment(
                    opId: opId, id: commentId, at: at,
                    body: CommentCreate(issueId: issueId, body: "Hi"))
            ),
            ("patchComment", .patchComment(opId: opId, id: commentId, at: at, body: commentPatch)),
            ("deleteComment", .deleteComment(opId: opId, id: commentId, at: at)),
            (
                "putLabel",
                .putLabel(
                    opId: opId, id: labelId, at: at,
                    body: LabelCreate(name: "backend", color: "#2D6CDF"))
            ),
            ("patchLabel", .patchLabel(opId: opId, id: labelId, at: at, body: labelPatch)),
            ("deleteLabel", .deleteLabel(opId: opId, id: labelId, at: at)),
            (
                "addLabel",
                .addLabel(
                    opId: opId, id: linkId, at: at,
                    issueId: issueId, labelId: labelId)
            ),
            ("removeLabel", .removeLabel(opId: opId, id: linkId, at: at)),
        ]
    }()

    @Test("every operation kind survives a round trip", arguments: allKinds)
    func everyKindRoundTrips(named: String, operation: SyncOperation) throws {
        let once = try JSONCoders.encoder.encode(operation)
        let decoded = try JSONCoders.decoder.decode(SyncOperation.self, from: once)
        let twice = try JSONCoders.encoder.encode(decoded)

        #expect(once == twice, "\(named) did not round trip")
        #expect(decoded.entity == operation.entity)
        #expect(decoded.kind == operation.kind)
    }

    /// A label link has no mutable fields, so this combination is not a valid
    /// operation and must fail rather than decode into something arbitrary.
    @Test("patching a label link is rejected as an invalid operation")
    func patchingALinkIsRejected() {
        let json = """
            {"opId":"018F3A9C-0000-7000-8000-0000000000A1","entity":"issueLabel",
             "kind":"patch","entityId":"018F3A9C-0000-7000-8000-000000000030",
             "clientTimestamp":"2025-09-04T15:33:20.123Z"}
            """

        #expect(throws: (any Error).self) {
            try JSONCoders.decoder.decode(SyncOperation.self, from: Data(json.utf8))
        }
    }

    @Test("a watermark can be built directly and rejects a negative sequence")
    func watermarkDirectConstruction() {
        #expect(Watermark(epoch: "01H8XYZ", sequence: 0) != nil)
        #expect(Watermark(epoch: "01H8XYZ", sequence: -1) == nil)
        #expect(Watermark(epoch: "", sequence: 1) == nil)
    }
}
