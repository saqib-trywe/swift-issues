import Core
import Foundation
import Testing

private struct IssueSnapshot: Codable {
    var key: IssueKey?
}

@Suite("IssueKey")
struct IssueKeyTests {

    @Test("parses a project key and number, and renders back identically")
    func parsesAndRenders() throws {
        let key = try #require(IssueKey("PROJ-142"))

        #expect(key.projectKey == ProjectKey("PROJ"))
        #expect(key.number == 142)
        #expect(key.wireValue == "PROJ-142")
    }

    @Test(
        "rejects malformed keys",
        arguments: [
            "PROJ",  // no number
            "PROJ-",  // missing number
            "-142",  // missing project key
            "proj-142",  // lowercase project key
            "P-142",  // project key too short
            "PROJ-0",  // numbering starts at 1
            "PROJ--142",
            "PROJ-14.2",
            "PROJ-142-3",
            "",
        ]
    )
    func rejectsMalformedKeys(raw: String) {
        #expect(IssueKey(raw) == nil)
    }

    /// An Issue created offline has no key until the server assigns one on first
    /// sync, so absence is a first-class state rather than an empty string.
    @Test("an unsynced issue encodes a null key rather than a placeholder string")
    func unsyncedIssueEncodesNull() throws {
        let data = try JSONEncoder().encode(IssueSnapshot(key: nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["key"] == nil || object["key"] is NSNull)
    }

    @Test("round trips through JSON")
    func roundTripsThroughJSON() throws {
        let decoded = try JSONDecoder().decode(
            IssueSnapshot.self,
            from: Data(#"{"key":"PROJ-142"}"#.utf8)
        )

        #expect(decoded.key == IssueKey("PROJ-142"))
    }

    @Test("a key encodes as its wire value")
    func encodesAsWireValue() throws {
        let snapshot = IssueSnapshot(key: IssueKey("PROJ-142"))

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["key"] as? String == "PROJ-142")
    }

    @Test("a malformed key in JSON is rejected rather than silently dropped")
    func malformedKeyInJSONThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IssueSnapshot.self, from: Data(#"{"key":"nonsense"}"#.utf8))
        }
    }

    /// The per-Project counter is monotonic and starts at 1, so there is no
    /// PROJ-0 and no negative numbering.
    @Test("numbering below 1 is unrepresentable", arguments: [0, -1])
    func numberingBelowOneIsRejected(number: Int) throws {
        let projectKey = try #require(ProjectKey("PROJ"))

        #expect(IssueKey(projectKey: projectKey, number: number) == nil)
    }
}
