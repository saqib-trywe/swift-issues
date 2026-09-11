import Foundation
import Security

/// Where a personal access token lives between invocations.
///
/// Keyed by server URL throughout, so pointing at a test instance cannot clobber
/// the credential for a real one (ticket 11).
protocol CredentialStore: Sendable {
    func token(forServer server: String) throws -> String?
    func store(_ token: String, forServer server: String) throws
    func remove(forServer server: String) throws
}

/// The macOS Keychain, as a generic password per server.
///
/// Not exercised in CI: `SecItem` access depends on the login keychain's lock
/// state, which on a hosted runner can prompt and then hang the job until the
/// timeout. `KeychainTests` runs only when `ISSUES_TEST_KEYCHAIN` is set.
struct KeychainCredentialStore: CredentialStore {
    let service: String

    init(service: String = "co.trywe.issues") {
        self.service = service
    }

    private func query(forServer server: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
    }

    func token(forServer server: String) throws -> String? {
        var query = query(forServer: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func store(_ token: String, forServer server: String) throws {
        // Delete first rather than branching on add-versus-update: an update with
        // no existing item fails, and the two-step keeps one code path.
        try? remove(forServer: server)

        var attributes = query(forServer: server)
        attributes[kSecValueData as String] = Data(token.utf8)
        // The token is only ever needed while someone is at the machine, and this
        // keeps it out of an unlocked-device backup.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func remove(forServer server: String) throws {
        let status = SecItemDelete(query(forServer: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(detail)"
    }
}

/// A `0600` file of `server<TAB>token` lines.
///
/// The fallback ticket 11 specified for Linux, which nothing targets any more —
/// it survives because it is what the tests drive, and because `ISSUES_*` env
/// deployments on a headless Mac have no unlocked keychain either.
struct FileCredentialStore: CredentialStore {
    let file: URL

    func token(forServer server: String) throws -> String? {
        try entries()[server]
    }

    func store(_ token: String, forServer server: String) throws {
        var all = try entries()
        all[server] = token
        try write(all)
    }

    func remove(forServer server: String) throws {
        var all = try entries()
        all[server] = nil
        try write(all)
    }

    private func entries() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let contents = try String(contentsOf: file, encoding: .utf8)
        var entries: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            entries[String(parts[0])] = String(parts[1])
        }
        return entries
    }

    private func write(_ entries: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Sorted so the file does not churn between writes.
        let contents = entries.sorted { $0.key < $1.key }
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n")

        // Created with its mode in the same call, so the token is never on disk
        // world-readable — not even for the moment an atomic write-then-chmod
        // would leave open. The cost is that this is not atomic: a crash
        // mid-write loses the file. That trade is deliberate, because a lost
        // token is recovered by logging in again and a leaked one is not.
        try? FileManager.default.removeItem(at: file)
        guard
            FileManager.default.createFile(
                atPath: file.path,
                contents: Data((contents + "\n").utf8),
                attributes: [.posixPermissions: 0o600])
        else {
            throw CLIError.malformedConfiguration("Could not write credentials to \(file.path).")
        }
    }
}
