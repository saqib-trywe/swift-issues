import Core
import Foundation
import Testing

@Suite("UUIDv7")
struct UUIDv7Tests {

    @Test("carries version 7 and the RFC 4122 variant bits")
    func carriesVersionAndVariant() {
        let uuid = UUIDv7.generate(millisecondsSince1970: 1_757_000_000_000)
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        #expect(bytes[6] >> 4 == 0x7)
        #expect(bytes[8] >> 6 == 0b10)
    }

    /// The point of v7 over v4: ids sort in creation order, so they index well
    /// and a client can generate them offline without losing ordering. See ADR 0003.
    @Test("ids generated later sort after ids generated earlier")
    func idsSortInCreationOrder() {
        let earlier = UUIDv7.generate(millisecondsSince1970: 1_757_000_000_000)
        let later = UUIDv7.generate(millisecondsSince1970: 1_757_000_000_001)

        #expect(earlier.uuidString < later.uuidString)
    }

    @Test("encodes the supplied timestamp in the leading 48 bits")
    func encodesTimestamp() {
        let millis: UInt64 = 1_757_000_000_000
        let uuid = UUIDv7.generate(millisecondsSince1970: millis)
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        let recovered = bytes[0..<6].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        #expect(recovered == millis)
    }

    @Test("two ids in the same millisecond still differ")
    func sameMillisecondIdsDiffer() {
        let a = UUIDv7.generate(millisecondsSince1970: 1_757_000_000_000)
        let b = UUIDv7.generate(millisecondsSince1970: 1_757_000_000_000)

        #expect(a != b)
    }
}
