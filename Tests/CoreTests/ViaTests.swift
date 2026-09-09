import Core
import Testing

@Suite("Via")
struct ViaTests {

    @Test(
        "known cases round trip through their wire value",
        arguments: [(Via.human, "human"), (Via.agent, "agent")]
    )
    func knownCasesRoundTrip(via: Via, wire: String) {
        #expect(via.wireValue == wire)
        #expect(Via(wireValue: wire) == via)
    }

    @Test("an unrecognised wire value is preserved verbatim, not coerced")
    func unrecognisedValueIsPreservedVerbatim() {
        let via = Via(wireValue: "workflow")

        #expect(via == .unknown("workflow"))
        #expect(via.wireValue == "workflow")
    }

    /// Attribution exists to answer "which of these did the bot file?". An
    /// unrecognised writer must not silently read as human. See ADR 0007.
    @Test("an unknown writer is not treated as human")
    func unknownWriterIsNotHuman() {
        #expect(Via(wireValue: "workflow") != .human)
    }
}
