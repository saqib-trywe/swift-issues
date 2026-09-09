import Core
import Foundation
import Testing

private struct IssueSnapshot: Codable {
    var dueDate: CivilDate?
}

@Suite("CivilDate")
struct CivilDateTests {

    @Test(
        "renders as a zero-padded YYYY-MM-DD wire value",
        arguments: [
            (2026, 9, 11, "2026-09-11"),
            (2026, 12, 1, "2026-12-01"),
            (1999, 1, 31, "1999-01-31"),
        ]
    )
    func rendersAsWireValue(year: Int, month: Int, day: Int, expected: String) throws {
        let date = try #require(CivilDate(year: year, month: month, day: day))

        #expect(date.wireValue == expected)
    }

    @Test(
        "a day that does not exist is unrepresentable",
        arguments: [
            (2026, 13, 1),  // month out of range
            (2026, 0, 1),
            (2026, 2, 30),  // February never has 30 days
            (2026, 4, 31),  // April has 30
            (2026, 1, 0),  // day out of range
            (2026, 2, 29),  // 2026 is not a leap year
            (1900, 2, 29),  // divisible by 100, not a leap year
        ]
    )
    func impossibleDaysAreRejected(year: Int, month: Int, day: Int) {
        #expect(CivilDate(year: year, month: month, day: day) == nil)
    }

    @Test(
        "real leap days are accepted",
        arguments: [(2028, 2, 29), (2000, 2, 29)]  // 2000 is divisible by 400
    )
    func leapDaysAreAccepted(year: Int, month: Int, day: Int) {
        #expect(CivilDate(year: year, month: month, day: day) != nil)
    }

    @Test("decodes from its wire value and re-encodes identically")
    func roundTripsThroughJSON() throws {
        let decoded = try JSONDecoder().decode(
            IssueSnapshot.self,
            from: Data(#"{"dueDate":"2026-09-11"}"#.utf8)
        )
        #expect(decoded.dueDate == CivilDate(year: 2026, month: 9, day: 11))

        let object = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded))
                as? [String: Any]
        )
        #expect(object["dueDate"] as? String == "2026-09-11")
    }

    /// The important rejection. If an instant parsed here, the timezone bug this
    /// type exists to prevent would come straight back in through the wire.
    @Test(
        "malformed values are rejected, including RFC 3339 instants",
        arguments: [
            #"{"dueDate":"2026-09-11T00:00:00Z"}"#,
            #"{"dueDate":"11/09/2026"}"#,
            #"{"dueDate":"2026-9-11"}"#,
            #"{"dueDate":"2026-02-30"}"#,
            #"{"dueDate":"tomorrow"}"#,
            #"{"dueDate":""}"#,
        ]
    )
    func malformedValuesAreRejected(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IssueSnapshot.self, from: Data(json.utf8))
        }
    }
}
