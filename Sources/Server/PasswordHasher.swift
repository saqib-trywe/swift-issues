import Crypto
import Foundation
import _CryptoExtras

/// Hashes and verifies passwords with scrypt.
///
/// ADR 0006 originally specified Argon2id. CryptoKit has no Argon2, and the
/// alternative was an unaudited third-party crypto library sitting directly in the
/// authentication path. scrypt is **memory-hard** — the property Argon2id was chosen
/// for — and comes from `swift-crypto`, which is Apple-maintained, BoringSSL-backed,
/// and already in this graph. See ADR 0006's amendment.
///
/// A password needs a slow, memory-hard function because it is low-entropy and
/// guessable. Note the contrast with session tokens, which are 256 bits of
/// randomness and are hashed with plain SHA-256: there is nothing there to guess, so
/// a KDF would add latency to every request and buy nothing.
public struct PasswordHasher: Sendable {
    public let rounds: Int
    public let blockSize: Int
    public let parallelism: Int

    static let derivedKeyBytes = 32
    static let saltBytes = 16
    static let algorithm = "scrypt"

    public init(rounds: Int, blockSize: Int, parallelism: Int) {
        self.rounds = rounds
        self.blockSize = blockSize
        self.parallelism = parallelism
    }

    /// OWASP's floor for scrypt: N = 2^17, r = 8, p = 1. Roughly 128MB per
    /// derivation, which is the cost that makes offline cracking expensive — and is
    /// affordable here because logins are rare and throttled.
    public static let production = PasswordHasher(
        rounds: 1 << 17, blockSize: 8, parallelism: 1)

    /// Cheap parameters for tests. Safe because the encoded form records its own
    /// parameters, so verification takes the same path either way.
    static let testing = PasswordHasher(rounds: 1 << 10, blockSize: 8, parallelism: 1)

    /// Returns `scrypt$N$r$p$salt$hash`, a PHC-shaped string.
    ///
    /// The parameters travel with the hash so they can be raised later without
    /// invalidating every stored password; not recording them would mean a forced
    /// reset for everybody the first time the cost needs increasing.
    public func hash(_ password: String) throws -> String {
        var salt = [UInt8](repeating: 0, count: Self.saltBytes)
        for index in salt.indices { salt[index] = UInt8.random(in: 0...255) }

        let derived: SymmetricKey = try KDF.Scrypt.deriveKey(
            from: Data(password.utf8),
            salt: salt,
            outputByteCount: Self.derivedKeyBytes,
            rounds: rounds,
            blockSize: blockSize,
            parallelism: parallelism
        )
        let bytes: [UInt8] = derived.withUnsafeBytes { Array($0) }

        let saltText: String = Data(salt).base64EncodedString()
        let hashText: String = Data(bytes).base64EncodedString()
        return "\(Self.algorithm)$\(rounds)$\(blockSize)$\(parallelism)$\(saltText)$\(hashText)"
    }

    /// Verifies a password against an encoded hash, reading the parameters from it.
    ///
    /// Throws on a malformed stored value rather than returning `false`: a corrupt
    /// hash is an operational problem, and reporting it as a wrong password would
    /// send someone to reset a password that was never the issue.
    public static func verify(_ password: String, against encoded: String) throws -> Bool {
        let parts: [String] = encoded.split(separator: "$", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 6, parts[0] == algorithm,
            let rounds = Int(parts[1]), let blockSize = Int(parts[2]),
            let parallelism = Int(parts[3]),
            let salt = Data(base64Encoded: parts[4]),
            let expected = Data(base64Encoded: parts[5])
        else {
            throw PasswordHashError.malformed
        }

        let derived: SymmetricKey = try KDF.Scrypt.deriveKey(
            from: Data(password.utf8),
            salt: Array(salt),
            outputByteCount: expected.count,
            rounds: rounds,
            blockSize: blockSize,
            parallelism: parallelism
        )
        let actual = Data(derived.withUnsafeBytes { Array($0) })

        // Constant-time comparison: a byte-by-byte early exit would leak how much of
        // the hash matched.
        return constantTimeEquals(actual, expected)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

public enum PasswordHashError: Error, Sendable {
    /// The stored value is not a hash this build can read.
    case malformed
}
