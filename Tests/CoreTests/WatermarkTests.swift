import Core
import Foundation
import Testing

private struct PullState: Codable {
    var since: Watermark?
}

@Suite("Watermark")
struct WatermarkTests {

    @Test("parses an epoch and sequence")
    func parses() throws {
        let watermark = try #require(Watermark("01H8XYZ:4210"))

        #expect(watermark.epoch == "01H8XYZ")
        #expect(watermark.sequence == 4210)
        #expect(watermark.wireValue == "01H8XYZ:4210")
    }

    @Test(
        "rejects malformed values",
        arguments: ["4210", "01H8XYZ", "01H8XYZ:", ":4210", "01H8XYZ:abc", "01H8XYZ:-1", "a:b:c", ""]
    )
    func rejectsMalformed(raw: String) {
        #expect(Watermark(raw) == nil)
    }

    @Test("round trips through JSON as an opaque string")
    func roundTripsThroughJSON() throws {
        let decoded = try JSONCoders.decoder.decode(
            PullState.self, from: Data(#"{"since":"01H8XYZ:4210"}"#.utf8))
        #expect(decoded.since == Watermark("01H8XYZ:4210"))

        let object = try #require(
            JSONSerialization.jsonObject(with: try JSONCoders.encoder.encode(decoded))
                as? [String: Any])
        #expect(object["since"] as? String == "01H8XYZ:4210")
    }

    /// A first sync has no watermark at all, which is a distinct state from
    /// sequence zero.
    @Test("a first sync has no watermark")
    func firstSyncHasNone() throws {
        let decoded = try JSONCoders.decoder.decode(
            PullState.self, from: Data(#"{"since":null}"#.utf8))

        #expect(decoded.since == nil)
    }

    @Test("within one epoch, a higher sequence is newer")
    func ordersWithinAnEpoch() throws {
        let earlier = try #require(Watermark("01H8XYZ:100"))
        let later = try #require(Watermark("01H8XYZ:200"))

        #expect(later.isNewer(than: earlier) == true)
        #expect(earlier.isNewer(than: later) == false)
    }

    /// Across epochs the question is meaningless: a restore rewinds the sequence,
    /// so 4210 in a new epoch is not "older" than 9000 in the previous one. Nil
    /// forces the caller to notice rather than inherit a wrong answer — the same
    /// choice as Status.category for an unknown status.
    @Test("across epochs the comparison is undefined rather than wrong")
    func comparisonAcrossEpochsIsUndefined() throws {
        let old = try #require(Watermark("01H8XYZ:9000"))
        let new = try #require(Watermark("01H9ABC:4210"))

        #expect(new.isNewer(than: old) == nil)
    }

    @Test("a watermark from a different epoch is detectable as stale")
    func staleEpochIsDetectable() throws {
        let held = try #require(Watermark("01H8XYZ:9000"))
        let server = try #require(Watermark("01H9ABC:1"))

        #expect(held.hasSameEpoch(as: server) == false)
        #expect(held.hasSameEpoch(as: try #require(Watermark("01H8XYZ:1"))))
    }
}
