import CryptoKit
import Foundation

/// Generates name-based UUIDs (RFC 9562 version 5, SHA-1 over a namespace).
///
/// Used so two clients creating the same Label offline in the same Project
/// independently derive the *same* id — the creates then collide intentionally
/// and merge, with no server round trip and no reconciliation UI. See ADR 0003.
///
/// The hash is SHA-1, which is broken for signatures but is what the standard
/// specifies here; this is a name-to-id mapping, not a security boundary.
public enum UUIDv5 {

    public static func generate(namespace: UUID, name: String) -> UUID {
        var input = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        input.append(contentsOf: Array(name.utf8))

        var digest = Array(Insecure.SHA1.hash(data: input).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50  // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80  // RFC 4122 variant

        return UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                digest[12], digest[13], digest[14], digest[15]
            )
        )
    }
}
