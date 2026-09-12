import Foundation
import TestSupport
import Testing

@testable import Core

@Suite("Expanded issue")
struct ExpandedIssueTests {

    private let issue = Issue.fixture(title: "Needs an assignee")

    /// The shape is additive, which is the whole reason it can be added to a live
    /// API: a client that knows nothing about expansion still decodes the issue.
    @Test("an expanded payload still decodes as a plain issue")
    func expandedPayloadStillDecodesAsAPlainIssue() throws {
        let expanded = ExpandedIssue(
            issue: issue, assignee: User.fixture(displayName: "Ada"))
        let data = try JSONCoders.encoder.encode(expanded)

        let plain = try JSONCoders.decoder.decode(Issue.self, from: data)
        #expect(plain.id == issue.id)
        #expect(plain.title == "Needs an assignee")
    }

    /// The expansion sits beside the id it resolves, not in place of it.
    @Test("the id and its expansion both appear")
    func idAndExpansionBothAppear() throws {
        let assignee = User.fixture(displayName: "Ada")
        var assigned = issue
        assigned.assigneeId = assignee.id

        let data = try JSONCoders.encoder.encode(
            ExpandedIssue(issue: assigned, assignee: assignee))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["assigneeId"] as? String == assignee.id.rawValue.uuidString)
        #expect((object["assignee"] as? [String: Any])?["displayName"] as? String == "Ada")
    }

    @Test("an unrequested expansion is absent rather than null")
    func unrequestedExpansionIsAbsent() throws {
        let data = try JSONCoders.encoder.encode(ExpandedIssue(issue: issue))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["assignee"] == nil)
        #expect(object["labels"] == nil)
    }

    /// Requested-and-none is a different answer from not-requested, and a client
    /// showing a label row needs to tell them apart.
    @Test("an empty expansion is distinguishable from an absent one")
    func emptyExpansionIsDistinguishableFromAbsent() throws {
        let requested = try JSONCoders.encoder.encode(
            ExpandedIssue(issue: issue, labels: []))
        let absent = try JSONCoders.encoder.encode(ExpandedIssue(issue: issue))

        #expect(try JSONCoders.decoder.decode(ExpandedIssue.self, from: requested).labels == [])
        #expect(try JSONCoders.decoder.decode(ExpandedIssue.self, from: absent).labels == nil)
    }

    @Test("every expansion round-trips")
    func everyExpansionRoundTrips() throws {
        let expanded = ExpandedIssue(
            issue: issue,
            labels: [Label.fixture(name: "bug")],
            assignee: User.fixture(displayName: "Ada"),
            reporter: User.fixture(displayName: "Mel"),
            project: Project.fixture(name: "Platform"))

        let decoded = try JSONCoders.decoder.decode(
            ExpandedIssue.self, from: try JSONCoders.encoder.encode(expanded))

        #expect(decoded.issue.id == issue.id)
        #expect(decoded.labels?.first?.name == "bug")
        #expect(decoded.assignee?.displayName == "Ada")
        #expect(decoded.reporter?.displayName == "Mel")
        #expect(decoded.project?.name == "Platform")
    }

    // MARK: Parsing

    @Test("a comma-separated list parses")
    func commaSeparatedListParses() throws {
        #expect(try Expansion.parse("labels,assignee") == [.labels, .assignee])
        #expect(try Expansion.parse(" labels , assignee ") == [.labels, .assignee])
    }

    @Test("an empty parameter parses to nothing")
    func emptyParameterParsesToNothing() throws {
        #expect(try Expansion.parse("").isEmpty)
        #expect(try Expansion.parse(",,").isEmpty)
    }

    /// Silently expanding nothing would look identical to a server that does not
    /// support the relationship, and the caller would have no way to tell.
    @Test("an unknown expansion is refused, naming the known ones")
    func unknownExpansionIsRefused() {
        #expect(throws: ExpansionError.unknown("comments")) {
            try Expansion.parse("labels,comments")
        }
        #expect(
            ExpansionError.unknown("comments").description.contains("assignee"))
    }

    /// Comments are never embedded: an issue with 200 of them must not be one
    /// response (ticket 06).
    @Test("comments are not an expansion")
    func commentsAreNotAnExpansion() {
        #expect(!Expansion.allCases.map(\.rawValue).contains("comments"))
    }
}
