import Testing

@testable import Core

/// Rules for the two fields that identify a person. Both are checked on the way
/// in only, like every other rule here.
@Suite("Email and display name validation")
struct IdentityValidationTests {

    @Test(
        "an ordinary address is accepted",
        arguments: [
            "saqib@example.com",
            "first.last@sub.example.co.uk",
            "plus+tag@example.com",
            "dashes-and_underscores@example-host.com",
        ])
    func ordinaryAddressIsAccepted(_ address: String) {
        #expect(Validation.email(address).isEmpty)
    }

    @Test(
        "a structurally wrong address is rejected",
        arguments: [
            "",
            "   ",
            "no-at-sign.example.com",
            "two@at@example.com",
            "@example.com",
            "nobody@",
            "spaces in@example.com",
            "nobody@localhost",
            "nobody@.example.com",
            "nobody@example.com.",
        ])
    func structurallyWrongAddressIsRejected(_ address: String) {
        #expect(!Validation.email(address).isEmpty, "'\(address)' was accepted")
    }

    @Test("an empty address reports 'required' rather than a shape complaint")
    func emptyAddressReportsRequired() {
        #expect(Validation.email("").first?.code == .required)
    }

    @Test("an over-long address is rejected by length")
    func overLongAddressIsRejectedByLength() {
        let address = String(repeating: "a", count: 320) + "@example.com"
        #expect(Validation.email(address).first?.code == .tooLong)
    }

    /// The code matters: a client branches on it, and "invalid" and "tooLong"
    /// need different corrections from the person typing.
    @Test("a malformed address reports 'invalid'")
    func malformedAddressReportsInvalid() {
        #expect(Validation.email("nope").first?.code == .invalid)
    }

    @Test("a display name is required")
    func displayNameIsRequired() {
        #expect(Validation.displayName("").first?.code == .required)
        #expect(Validation.displayName("   ").first?.code == .required)
    }

    @Test("an over-long display name is rejected")
    func overLongDisplayNameIsRejected() {
        #expect(Validation.displayName(String(repeating: "a", count: 201)).first?.code == .tooLong)
    }

    @Test("an ordinary display name is accepted")
    func ordinaryDisplayNameIsAccepted() {
        #expect(Validation.displayName("Saqib").isEmpty)
        #expect(Validation.displayName(String(repeating: "a", count: 200)).isEmpty)
    }

    /// The lists exist so a CLI can name the alternatives in an error message;
    /// `unknown` has no fixed value to name and must stay out.
    @Test("the known value lists exclude unknown")
    func knownValueListsExcludeUnknown() {
        #expect(Status.known.count == 4)
        #expect(Priority.known.count == 5)
        #expect(Status.known.allSatisfy { $0.category != nil })
        #expect(!Priority.known.map(\.wireValue).contains(""))
    }
}
