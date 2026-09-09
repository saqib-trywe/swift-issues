import Core
import Foundation
import Testing

@Suite("User")
struct UserTests {

    @Test("decodes from the wire shape in ticket 06")
    func decodesFromWireShape() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000001",
              "email": "saqib@example.com",
              "displayName": "Saqib",
              "role": "admin",
              "active": true,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        let user = try JSONCoders.decoder.decode(User.self, from: Data(json.utf8))

        #expect(user.email == "saqib@example.com")
        #expect(user.displayName == "Saqib")
        #expect(user.role == .admin)
        #expect(user.active)
    }

    /// Users are deactivated, never deleted — they are referenced as reporter,
    /// assignee and comment author permanently, so there is no deletedAt here.
    @Test("a deactivated user decodes as inactive rather than absent")
    func deactivatedUserIsInactive() throws {
        let json = """
            {
              "id": "018f3a9c-0000-7000-8000-000000000001",
              "email": "jo@example.com", "displayName": "Jo", "role": "member",
              "active": false,
              "createdAt": "2025-09-04T15:33:20.123Z",
              "updatedAt": "2025-09-04T15:33:20.123Z"
            }
            """

        let user = try JSONCoders.decoder.decode(User.self, from: Data(json.utf8))

        #expect(user.active == false)
    }
}
