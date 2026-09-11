import Foundation
import Testing

@testable import CLI

/// The real Keychain, exercised only when asked for.
///
/// `SecItem` access depends on the login keychain's lock state, and on a hosted
/// CI runner it can prompt and then block until the job times out — which reads
/// as an unrelated hang. Run with `ISSUES_TEST_KEYCHAIN=1 swift test` on a real
/// machine to check this path.
@Suite(
    "Keychain",
    .enabled(if: ProcessInfo.processInfo.environment["ISSUES_TEST_KEYCHAIN"] != nil))
struct KeychainTests {

    private let service = "co.trywe.issues.tests"

    @Test("a token round-trips through the Keychain")
    func tokenRoundTrips() throws {
        let store = KeychainCredentialStore(service: service)
        let server = "https://keychain-test-\(UUID().uuidString).example.test"
        defer { try? store.remove(forServer: server) }

        try store.store("issues_pat_abc", forServer: server)
        #expect(try store.token(forServer: server) == "issues_pat_abc")

        try store.remove(forServer: server)
        #expect(try store.token(forServer: server) == nil)
    }

    /// `store` deletes before adding, so a re-login replaces rather than failing
    /// with a duplicate-item error.
    @Test("storing twice replaces rather than failing")
    func storingTwiceReplaces() throws {
        let store = KeychainCredentialStore(service: service)
        let server = "https://keychain-test-\(UUID().uuidString).example.test"
        defer { try? store.remove(forServer: server) }

        try store.store("first", forServer: server)
        try store.store("second", forServer: server)
        #expect(try store.token(forServer: server) == "second")
    }
}
