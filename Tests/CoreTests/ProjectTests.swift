import Core
import Foundation
import Testing

@Suite("Project")
struct ProjectTests {

    @Test("decodes from the wire shape in ticket 06")
    func decodesFromWireShape() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000002",
              "key": "PROJ",
              "name": "Platform",
              "description": "Server and sync work",
              "archived": false,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        let project = try JSONCoders.decoder.decode(Project.self, from: Data(json.utf8))

        #expect(project.key == ProjectKey("PROJ"))
        #expect(project.name == "Platform")
        #expect(project.archived == false)
    }

    /// The key is validated at the boundary, not assumed: an invalid key would
    /// otherwise be baked into every Issue Key for the Project.
    @Test("rejects a project whose key is not a valid ProjectKey")
    func rejectsInvalidKey() {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000002",
              "key": "proj", "name": "Platform", "description": "", "archived": false,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        #expect(throws: (any Error).self) {
            try JSONCoders.decoder.decode(Project.self, from: Data(json.utf8))
        }
    }
}
