import Core
import Foundation
import Testing

private struct EditIssue: Codable {
    var title: Settable<String>
}

@Suite("Settable")
struct SettableTests {

    @Test("an absent key decodes as unchanged")
    func absentKeyIsUnchanged() throws {
        let body = try JSONDecoder().decode(EditIssue.self, from: Data(#"{}"#.utf8))

        #expect(body.title == .unchanged)
    }

    @Test("a present value decodes as set")
    func presentValueIsSet() throws {
        let body = try JSONDecoder().decode(
            EditIssue.self, from: Data(#"{"title":"Renamed"}"#.utf8))

        #expect(body.title == .set("Renamed"))
    }

    /// There is no `.cleared`, so a null has nowhere to go. Failing loudly is
    /// right: the alternative is silently treating "clear this" as "leave it",
    /// which would swallow a caller's intent.
    @Test("an explicit null is rejected rather than silently ignored")
    func explicitNullIsRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditIssue.self, from: Data(#"{"title":null}"#.utf8))
        }
    }

    @Test("unchanged omits its key when encoded in a keyed container")
    func unchangedOmitsKey() throws {
        let data = try JSONEncoder().encode(EditIssue(title: .unchanged))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object.keys.contains("title") == false)
    }

    @Test("set encodes its value")
    func setEncodesValue() throws {
        let data = try JSONEncoder().encode(EditIssue(title: .set("Renamed")))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["title"] as? String == "Renamed")
    }

    /// Same guard as `Patchable`: "absent" is meaningless outside a keyed
    /// container, and emitting anything there would be a value the server acts on.
    @Test("unchanged outside a keyed container throws")
    func unchangedOutsideKeyedContainerThrows() {
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode([Settable<String>.unchanged])
        }
    }

    @Test("set encodes normally outside a keyed container")
    func setEncodesOutsideKeyedContainer() throws {
        let data = try JSONEncoder().encode([Settable<String>.set("a")])
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [Any])

        #expect(array.first as? String == "a")
    }

    /// Outside a keyed container the container overload does not apply, so this
    /// exercises the standalone initialiser.
    @Test("decodes outside a keyed container")
    func decodesOutsideKeyedContainer() throws {
        let values = try JSONDecoder().decode([Settable<String>].self, from: Data(#"["a"]"#.utf8))

        #expect(values == [.set("a")])
    }
}
