import Core
import Foundation
import Testing

@testable import Server

@Suite("Password hashing")
struct PasswordHashingTests {

    /// Test-cost parameters. The encoded form records its own parameters, so a hash
    /// made cheaply here still verifies through the same code path production uses.
    private let hasher = PasswordHasher.testing

    @Test("a password verifies against its own hash")
    func passwordVerifies() throws {
        let encoded: String = try hasher.hash("correct horse battery staple")

        #expect(try PasswordHasher.verify("correct horse battery staple", against: encoded))
    }

    @Test("a wrong password does not verify")
    func wrongPasswordFails() throws {
        let encoded: String = try hasher.hash("correct horse battery staple")

        #expect(try PasswordHasher.verify("Correct horse battery staple", against: encoded) == false)
        #expect(try PasswordHasher.verify("", against: encoded) == false)
    }

    /// A per-password salt, so two users with the same password do not share a hash
    /// and a stolen database cannot be attacked once for many accounts.
    @Test("the same password hashes differently every time")
    func saltMakesHashesUnique() throws {
        let first: String = try hasher.hash("correct horse battery staple")
        let second: String = try hasher.hash("correct horse battery staple")

        #expect(first != second)
        #expect(try PasswordHasher.verify("correct horse battery staple", against: second))
    }

    /// Parameters travel with the hash, so they can be raised later without
    /// invalidating every stored password — the cost of *not* recording them is a
    /// forced reset for everybody.
    @Test("the encoded form records its own parameters")
    func encodedFormRecordsParameters() throws {
        let encoded: String = try hasher.hash("correct horse battery staple")
        let parts: [String] = encoded.split(separator: "$").map(String.init)

        #expect(parts.first == "scrypt")
        #expect(parts.count == 6)
        #expect(Int(parts[1]) == hasher.rounds)
    }

    /// The point of recording parameters: a hash written under different settings
    /// still verifies.
    @Test("a hash made with different parameters still verifies")
    func hashAcrossParameterChange() throws {
        let cheap: String = try PasswordHasher(rounds: 1 << 9, blockSize: 8, parallelism: 1)
            .hash("correct horse battery staple")
        let dearer: String = try PasswordHasher(rounds: 1 << 10, blockSize: 8, parallelism: 1)
            .hash("correct horse battery staple")

        #expect(try PasswordHasher.verify("correct horse battery staple", against: cheap))
        #expect(try PasswordHasher.verify("correct horse battery staple", against: dearer))
    }

    @Test("a malformed stored hash is rejected rather than treated as a match")
    func malformedHashIsRejected() {
        for broken in ["", "scrypt", "scrypt$1$2$3", "bcrypt$1$8$1$aaaa$bbbb", "not-a-hash"] {
            #expect(throws: (any Error).self) {
                try PasswordHasher.verify("anything", against: broken)
            }
        }
    }

    /// Production parameters are memory-hard, which is the property scrypt was
    /// chosen for. Asserted rather than commented, so a later "optimisation" that
    /// lowered them would fail here.
    @Test("production parameters stay memory-hard")
    func productionParametersAreMemoryHard() {
        // OWASP's floor for scrypt is N = 2^17, r = 8, p = 1.
        #expect(PasswordHasher.production.rounds >= 1 << 17)
        #expect(PasswordHasher.production.blockSize >= 8)
    }
}

@Suite("Password rules")
struct PasswordRuleTests {

    /// ADR 0006: minimum 12 characters, no composition rules, no rotation — current
    /// NIST guidance. Length is the only thing that reliably helps.
    @Test("a password of at least 12 characters is accepted")
    func longEnoughIsAccepted() {
        #expect(Validation.password("correct horse").isEmpty)
        #expect(Validation.password("aaaaaaaaaaaa").isEmpty)
    }

    @Test("a short password is rejected", arguments: ["", "short", "aaaaaaaaaaa"])
    func shortIsRejected(raw: String) {
        let failures = Validation.password(raw)

        #expect(failures.map(\.code) == [.tooShort])
        #expect(failures.first?.field == "password")
    }

    /// Deliberately no composition rules: requiring a digit and a symbol pushes
    /// people toward "Password1!" and is not what NIST recommends.
    @Test("no composition rules are imposed")
    func noCompositionRules() {
        #expect(Validation.password("aaaaaaaaaaaaaaaaaaaa").isEmpty)
        #expect(Validation.password("            ").isEmpty)
    }
}
