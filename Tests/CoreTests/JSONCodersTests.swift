import Core
import Foundation
import Testing

private struct Stamped: Codable, Equatable {
    var createdAt: Date
}

@Suite("JSONCoders")
struct JSONCodersTests {

    /// Ticket 06: RFC 3339, explicit Z, millisecond precision. Foundation's
    /// default `.iso8601` strategy drops fractional seconds, so two records
    /// written in the same second would be indistinguishable on the wire.
    @Test("encodes instants as RFC 3339 with an explicit Z and milliseconds")
    func encodesRFC3339WithMilliseconds() throws {
        let stamped = Stamped(createdAt: Date(timeIntervalSince1970: 1_757_000_000.123))

        let data = try JSONCoders.encoder.encode(stamped)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["createdAt"] as? String == "2025-09-04T15:33:20.123Z")
    }

    @Test("decodes what it encodes")
    func roundTrips() throws {
        let original = Stamped(createdAt: Date(timeIntervalSince1970: 1_757_000_000.123))

        let decoded = try JSONCoders.decoder.decode(
            Stamped.self,
            from: try JSONCoders.encoder.encode(original)
        )

        #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
    }

    @Test("decodes instants without fractional seconds, which servers may omit")
    func decodesWithoutFractionalSeconds() throws {
        let decoded = try JSONCoders.decoder.decode(
            Stamped.self,
            from: Data(#"{"createdAt":"2025-09-04T15:33:20Z"}"#.utf8)
        )

        #expect(decoded.createdAt.timeIntervalSince1970 == 1_757_000_000)
    }

    @Test(
        "rejects values that are not RFC 3339 instants",
        arguments: [
            #"{"createdAt":"2025-09-04"}"#,
            #"{"createdAt":"04/09/2025 15:33"}"#,
            #"{"createdAt":"2025-09-04T15:33:20+01:00"}"#,
            #"{"createdAt":"yesterday"}"#,
        ]
    )
    func rejectsNonRFC3339(json: String) {
        #expect(throws: (any Error).self) {
            try JSONCoders.decoder.decode(Stamped.self, from: Data(json.utf8))
        }
    }
}
