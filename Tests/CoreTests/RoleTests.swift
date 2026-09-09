import Core
import Testing

@Suite("Role")
struct RoleTests {

    @Test(
        "known cases round trip through their wire value",
        arguments: [(Role.member, "member"), (Role.admin, "admin")]
    )
    func knownCasesRoundTrip(role: Role, wire: String) {
        #expect(role.wireValue == wire)
        #expect(Role(wireValue: wire) == role)
    }

    /// Leniency matters here too: a server that gains a role this build has never
    /// heard of must not break the client's ability to sync.
    @Test("an unrecognised wire value is preserved verbatim, not coerced")
    func unrecognisedValueIsPreservedVerbatim() {
        let role = Role(wireValue: "auditor")

        #expect(role == .unknown("auditor"))
        #expect(role.wireValue == "auditor")
    }

    /// Deliberate: an unrecognised role must never be treated as an Admin, and
    /// equally must not silently gain Member rights. Callers decide explicitly.
    @Test("an unknown role is neither member nor admin")
    func unknownRoleIsNeitherKnownRole() {
        let role = Role(wireValue: "auditor")

        #expect(role != .member)
        #expect(role != .admin)
    }
}
