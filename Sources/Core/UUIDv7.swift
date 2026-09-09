import Foundation

/// Generates time-ordered UUIDs (RFC 9562 version 7).
///
/// Foundation's `UUID()` is version 4 — uniformly random, so ids arrive in no
/// useful order and index poorly. Version 7 puts a millisecond timestamp in the
/// leading 48 bits, so ids sort in creation order while still being generatable
/// offline with no coordination. See ADR 0003.
public enum UUIDv7 {

    /// Generates an id stamped with the current time.
    public static func generate() -> UUID {
        generate(millisecondsSince1970: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    /// Generates an id stamped with the supplied time.
    ///
    /// The timestamp is a parameter so ordering is testable without sleeping.
    public static func generate(millisecondsSince1970 millis: UInt64) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)

        // Bytes 0–5: big-endian millisecond timestamp.
        for index in 0..<6 {
            bytes[index] = UInt8((millis >> (8 * (5 - UInt64(index)))) & 0xFF)
        }

        // Bytes 6–15: random, then overwrite the version and variant bits.
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70  // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant

        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}
