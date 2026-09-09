import Core
import Foundation
import Testing

// Swift Testing exports its own `Comment`, so the domain type is aliased here.
private typealias Comment = Core.Comment

@Suite("Comment")
struct CommentTests {

    @Test("decodes from the wire shape in ticket 06")
    func decodesFromWireShape() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000010",
              "issueId": "018f3a9c-0000-7000-8000-000000000020",
              "authorId": "018f3a9c-0000-7000-8000-000000000001",
              "body": "Partial index on state='pending' should cover it.",
              "via": "human",
              "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        let comment = try JSONCoders.decoder.decode(Comment.self, from: Data(json.utf8))

        #expect(comment.body == "Partial index on state='pending' should cover it.")
        #expect(comment.via == .human)
        #expect(comment.isDeleted == false)
    }

    /// Deleting a comment clears its text everywhere: people delete comments
    /// because of what is *in* them. The tombstone keeps only ids and timestamps,
    /// so `body` must be absent rather than an empty string. See ticket 01.
    @Test("a deleted comment has no body, not an empty one")
    func deletedCommentHasNoBody() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000010",
              "issueId": "018f3a9c-0000-7000-8000-000000000020",
              "authorId": "018f3a9c-0000-7000-8000-000000000001",
              "body": null,
              "via": "human",
              "deletedAt": "2025-09-05T09:00:00.000Z",
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-05T09:00:00.000Z"
            }
            """

        let comment = try JSONCoders.decoder.decode(Comment.self, from: Data(json.utf8))

        #expect(comment.body == nil)
        #expect(comment.isDeleted)
    }

    @Test("an agent-authored comment is attributable")
    func agentAuthoredCommentIsAttributable() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000011",
              "issueId": "018f3a9c-0000-7000-8000-000000000020",
              "authorId": "018f3a9c-0000-7000-8000-000000000001",
              "body": "Filed follow-up PROJ-143.", "via": "agent", "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        let comment = try JSONCoders.decoder.decode(Comment.self, from: Data(json.utf8))

        #expect(comment.via == .agent)
    }
}
