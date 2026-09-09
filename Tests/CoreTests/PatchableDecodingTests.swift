import Core
import Foundation
import Testing

/// A stand-in for a real PATCH body. `Patchable` only has three distinguishable
/// states relative to a containing keyed container, so it can only be tested
/// through one.
private struct EditIssue: Decodable {
    var title: Patchable<String>
}

@Suite("Patchable decoding")
struct PatchableDecodingTests {

    @Test("an absent key decodes as unchanged")
    func absentKeyDecodesAsUnchanged() throws {
        let json = Data(#"{}"#.utf8)

        let body = try JSONDecoder().decode(EditIssue.self, from: json)

        #expect(body.title == .unchanged)
    }

    @Test("an explicit null decodes as cleared")
    func explicitNullDecodesAsCleared() throws {
        let json = Data(#"{"title": null}"#.utf8)

        let body = try JSONDecoder().decode(EditIssue.self, from: json)

        #expect(body.title == .cleared)
    }

    @Test("a present value decodes as set")
    func presentValueDecodesAsSet() throws {
        let json = Data(#"{"title": "Sync queue stalls behind a quarantined op"}"#.utf8)

        let body = try JSONDecoder().decode(EditIssue.self, from: json)

        #expect(body.title == .set("Sync queue stalls behind a quarantined op"))
    }
}
