import Core
import Foundation
import Testing

private struct IssueSnapshot: Codable {
    var status: Status
}

@Suite("Status")
struct StatusTests {

    @Test(
        "known cases carry their lowerCamelCase wire value",
        arguments: [
            (Status.todo, "todo"),
            (Status.inProgress, "inProgress"),
            (Status.done, "done"),
            (Status.cancelled, "cancelled"),
        ]
    )
    func knownCasesCarryWireValue(status: Status, expected: String) {
        #expect(status.wireValue == expected)
    }

    @Test(
        "known wire values map back to their case",
        arguments: [
            ("todo", Status.todo),
            ("inProgress", Status.inProgress),
            ("done", Status.done),
            ("cancelled", Status.cancelled),
        ]
    )
    func knownWireValuesMapBack(wire: String, expected: Status) {
        #expect(Status(wireValue: wire) == expected)
    }

    /// A self-hosted server can be upgraded ahead of its clients. Coercing an
    /// unrecognised status to a default would corrupt data on the way back up;
    /// throwing would break sync for the whole installed base at once. See
    /// ticket 06.
    @Test("an unrecognised wire value is preserved verbatim, not coerced")
    func unrecognisedValueIsPreservedVerbatim() {
        let status = Status(wireValue: "triaged")

        #expect(status == .unknown("triaged"))
        #expect(status.wireValue == "triaged")
    }

    @Test("an unknown value survives a JSON round trip verbatim")
    func unknownValueSurvivesJSONRoundTrip() throws {
        let decoded = try JSONDecoder().decode(
            IssueSnapshot.self,
            from: Data(#"{"status":"triaged"}"#.utf8)
        )
        #expect(decoded.status == .unknown("triaged"))

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        #expect(object["status"] as? String == "triaged")
    }

    @Test(
        "known cases are either open or closed",
        arguments: [
            (Status.todo, Status.Category.open),
            (Status.inProgress, Status.Category.open),
            (Status.done, Status.Category.closed),
            (Status.cancelled, Status.Category.closed),
        ]
    )
    func knownCasesHaveACategory(status: Status, expected: Status.Category) {
        #expect(status.category == expected)
    }

    /// An unrecognised status has no defensible category: calling it open hides
    /// finished work, calling it closed hides live work. Callers must decide
    /// explicitly rather than inherit a wrong default.
    @Test("an unknown status has no category")
    func unknownStatusHasNoCategory() {
        #expect(Status.unknown("triaged").category == nil)
    }
}
