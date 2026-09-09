import Core
import Foundation
import Testing

// Stand-in phantom types. Real use is `Issue.ID`, `Project.ID`.
private enum Widget {}

private struct Reference: Codable {
    var widget: ID<Widget>
}

@Suite("ID")
struct IDTests {

    /// Phantom typing is a compile-time property, so it is asserted by
    /// construction: a function taking `ID<Widget>` will not accept an
    /// `ID<Gadget>`, and that failure is a build error rather than a test.
    /// What is testable is that the phantom leaves no trace on the wire.
    @Test("crosses the wire as a bare UUID string, with no phantom type visible")
    func encodesAsBareUUIDString() throws {
        let uuid = UUID()
        let data = try JSONEncoder().encode(Reference(widget: ID<Widget>(uuid)))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["widget"] as? String == uuid.uuidString)
    }

    @Test("decodes from a bare UUID string")
    func decodesFromBareUUIDString() throws {
        let uuid = UUID()
        let decoded = try JSONDecoder().decode(
            Reference.self,
            from: Data(#"{"widget":"\#(uuid.uuidString)"}"#.utf8)
        )

        #expect(decoded.widget == ID<Widget>(uuid))
    }

    @Test("rejects a value that is not a UUID")
    func rejectsNonUUID() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Reference.self, from: Data(#"{"widget":"PROJ-142"}"#.utf8))
        }
    }

    /// New ids must be v7, not Foundation's default v4, so they sort in creation
    /// order (ADR 0003). Note the guarantee is across milliseconds: ids minted
    /// within the same millisecond have random tails and no defined order
    /// between them, which is why this asserts the version rather than ordering.
    @Test("a freshly generated id is version 7, not Foundation's v4 default")
    func freshIDsAreVersion7() {
        let bytes = withUnsafeBytes(of: ID<Widget>().rawValue.uuid) { Array($0) }

        #expect(bytes[6] >> 4 == 0x7)
    }

    @Test("describes itself as its bare UUID string, for logs and CLI output")
    func describesItselfAsUUIDString() {
        let uuid = UUID()

        #expect(String(describing: ID<Widget>(uuid)) == uuid.uuidString)
    }
}
