import Core
import Foundation
import Testing

@Suite("IssueLabel")
struct IssueLabelTests {

    /// Label membership is a record, not a set-valued field, so two users adding
    /// different labels offline both survive rather than one silently losing.
    /// See ADR 0003.
    @Test("decodes as a link between one issue and one label")
    func decodesAsLink() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000030",
              "issueId": "018f3a9c-0000-7000-8000-000000000020",
              "labelId": "018f3a9c-0000-7000-8000-000000000003",
              "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        let link = try JSONCoders.decoder.decode(IssueLabel.self, from: Data(json.utf8))

        #expect(link.issueId.description == "018F3A9C-0000-7000-8000-000000000020")
        #expect(link.isDeleted == false)
    }

    @Test("removal is a tombstone on the link, not a deletion")
    func removalIsATombstone() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000030",
              "issueId": "018f3a9c-0000-7000-8000-000000000020",
              "labelId": "018f3a9c-0000-7000-8000-000000000003",
              "deletedAt": "2025-09-05T09:00:00.000Z",
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-05T09:00:00.000Z"
            }
            """

        let link = try JSONCoders.decoder.decode(IssueLabel.self, from: Data(json.utf8))

        #expect(link.isDeleted)
    }
}
