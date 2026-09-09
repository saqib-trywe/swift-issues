import Core
import Foundation
import Testing

private struct EditIssue: Encodable {
    var title: Patchable<String>
}

@Suite("Patchable encoding")
struct PatchableEncodingTests {

    /// Parsed rather than string-compared: whether the key is *present* is the
    /// behaviour under test, and string comparison would couple these tests to
    /// key ordering and whitespace.
    private func encodedObject(_ body: EditIssue) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("unchanged omits the key entirely")
    func unchangedOmitsTheKey() throws {
        let object = try encodedObject(EditIssue(title: .unchanged))

        #expect(object.keys.contains("title") == false)
    }

    @Test("cleared emits an explicit null")
    func clearedEmitsNull() throws {
        let object = try encodedObject(EditIssue(title: .cleared))

        #expect(object.keys.contains("title"))
        #expect(object["title"] is NSNull)
    }

    @Test("set emits the value")
    func setEmitsTheValue() throws {
        let object = try encodedObject(EditIssue(title: .set("Add partial index")))

        #expect(object["title"] as? String == "Add partial index")
    }

    /// `.unchanged` means "this key is absent", which only has meaning inside a
    /// keyed container. Encoding it anywhere else must fail loudly rather than
    /// emit `null`, which the server would read as "clear this field".
    @Test("unchanged outside a keyed container throws rather than emitting null")
    func unchangedOutsideKeyedContainerThrows() throws {
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode([Patchable<String>.unchanged])
        }
    }

    /// Pins the asymmetry: outside a keyed container `.unchanged` throws (above),
    /// but `.cleared` and `.set` still have a sensible representation.
    @Test("cleared and set encode normally outside a keyed container")
    func clearedAndSetEncodeOutsideKeyedContainer() throws {
        let data = try JSONEncoder().encode([Patchable<String>.set("a"), .cleared])
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [Any])

        #expect(array.count == 2)
        #expect(array[0] as? String == "a")
        #expect(array[1] is NSNull)
    }
}
