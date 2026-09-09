import Core
import Foundation
import Testing

@Suite("Label")
struct LabelTests {

    private let projectId = Project.ID(UUID(uuidString: "018f3a9c-0000-7000-8000-000000000002")!)

    @Test("decodes from the wire shape in ticket 06")
    func decodesFromWireShape() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000003",
              "projectId": "018f3a9c-0000-7000-8000-000000000002",
              "name": "backend",
              "color": "#2D6CDF",
              "deletedAt": null,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        let label = try JSONCoders.decoder.decode(Label.self, from: Data(json.utf8))

        #expect(label.name == "backend")
        #expect(label.color == "#2D6CDF")
        #expect(label.deletedAt == nil)
    }

    /// ADR 0003: two clients creating "backend" offline in the same Project must
    /// independently generate the *same* id, so the creates collide intentionally
    /// and merge with no reconciliation UI.
    @Test("the id is derived deterministically from project and name")
    func idIsDerivedDeterministically() {
        let first = Label.deriveID(projectId: projectId, name: "backend")
        let second = Label.deriveID(projectId: projectId, name: "backend")

        #expect(first == second)
    }

    @Test(
        "derivation normalises case and surrounding whitespace",
        arguments: ["backend", "Backend", "BACKEND", "  backend  "]
    )
    func derivationNormalises(name: String) {
        #expect(
            Label.deriveID(projectId: projectId, name: name)
                == Label.deriveID(projectId: projectId, name: "backend"))
    }

    @Test("different names and different projects derive different ids")
    func derivationDistinguishes() {
        let other = Project.ID(UUID(uuidString: "018f3a9c-0000-7000-8000-0000000000FF")!)

        #expect(
            Label.deriveID(projectId: projectId, name: "backend")
                != Label.deriveID(projectId: projectId, name: "frontend"))
        #expect(
            Label.deriveID(projectId: projectId, name: "backend")
                != Label.deriveID(projectId: other, name: "backend"))
    }

    @Test("derived ids are UUID version 5, so they are stable across builds")
    func derivedIDsAreVersion5() {
        let bytes = withUnsafeBytes(of: Label.deriveID(projectId: projectId, name: "backend").rawValue.uuid) {
            Array($0)
        }

        #expect(bytes[6] >> 4 == 0x5)
        #expect(bytes[8] >> 6 == 0b10)
    }
}
