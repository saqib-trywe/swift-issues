import Core
import Foundation
import TestSupport
import Testing

// Swift Testing exports its own `Issue` and `Comment`.
private typealias Issue = Core.Issue
private typealias Comment = Core.Comment

/// Round trips are asserted as encode → decode → encode, comparing the two
/// payloads rather than the values. Instants are `Double` seconds, so a value
/// like `.123` is not exactly representable and direct equality after a
/// millisecond-precision round trip would be comparing float bits.
@Suite("Entity round trips")
struct EntityRoundTripTests {

    private func assertStable<T: Codable>(_ original: T, as type: T.Type) throws {
        let once = try JSONCoders.encoder.encode(original)
        let decoded = try JSONCoders.decoder.decode(type, from: once)
        let twice = try JSONCoders.encoder.encode(decoded)

        #expect(once == twice)
    }

    @Test("User survives a round trip")
    func userRoundTrips() throws {
        try assertStable(User.fixture(role: .admin, active: false), as: User.self)
    }

    @Test("Project survives a round trip")
    func projectRoundTrips() throws {
        try assertStable(Project.fixture(archived: true), as: Project.self)
    }

    @Test("Label survives a round trip")
    func labelRoundTrips() throws {
        try assertStable(Label.fixture(deletedAt: Fixtures.epoch), as: Label.self)
    }

    @Test("IssueLabel survives a round trip")
    func issueLabelRoundTrips() throws {
        try assertStable(IssueLabel.fixture(deletedAt: Fixtures.epoch), as: IssueLabel.self)
    }

    @Test("Comment survives a round trip, including a cleared body")
    func commentRoundTrips() throws {
        try assertStable(Comment.fixture(via: .agent), as: Comment.self)
        try assertStable(
            Comment.fixture(body: nil, deletedAt: Fixtures.epoch), as: Comment.self)
    }

    @Test("Issue survives a round trip, keyed and unkeyed")
    func issueRoundTrips() throws {
        try assertStable(
            Issue.fixture(
                status: .inProgress,
                priority: .urgent,
                assigneeId: User.ID(),
                dueDate: CivilDate(year: 2026, month: 9, day: 11)
            ),
            as: Issue.self
        )
        // An offline-created Issue: no key yet.
        try assertStable(Issue.fixture(key: nil), as: Issue.self)
    }

    /// An unrecognised status must survive the client untouched, or a lagging
    /// client would corrupt data on the way back up. See ticket 06.
    @Test("an unknown status survives a full re-encode verbatim")
    func unknownStatusSurvivesReencode() throws {
        let original = Issue.fixture(status: .unknown("triaged"))

        let decoded = try JSONCoders.decoder.decode(
            Issue.self, from: try JSONCoders.encoder.encode(original))
        let object = try #require(
            JSONSerialization.jsonObject(with: try JSONCoders.encoder.encode(decoded))
                as? [String: Any])

        #expect(object["status"] as? String == "triaged")
    }
}
