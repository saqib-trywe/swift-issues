import Foundation

/// A client's resumable position in the server's change stream.
///
/// Opaque by contract (ticket 06) and made of two parts: an **epoch** and a
/// **sequence**. The sequence alone would be unsafe, because
/// `issues-server restore` rewinds the counter and reuses numbers for entirely
/// different changes — a client holding sequence 9000 against a restored server
/// would see nothing forever, believing it was current while silently diverging,
/// with no error raised anywhere. A new epoch on restore turns that into a
/// one-time full resync. See ticket 09.
public struct Watermark: Hashable, Sendable {
    public let epoch: String
    public let sequence: Int

    public init?(epoch: String, sequence: Int) {
        guard !epoch.isEmpty, sequence >= 0 else { return nil }
        self.epoch = epoch
        self.sequence = sequence
    }

    /// `nil` for anything that is not `<epoch>:<sequence>`.
    public init?(_ wireValue: String) {
        let parts = wireValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
            parts[1].utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let sequence = Int(parts[1])
        else { return nil }
        self.init(epoch: String(parts[0]), sequence: sequence)
    }

    public var wireValue: String { "\(epoch):\(sequence)" }

    public func hasSameEpoch(as other: Watermark) -> Bool { epoch == other.epoch }

    /// `nil` when the epochs differ, because the comparison is then meaningless:
    /// a restore rewinds the sequence, so a high number in an old epoch says
    /// nothing about a low number in a new one. Forcing the caller to handle that
    /// is the point — the alternative is a confidently wrong answer.
    public func isNewer(than other: Watermark) -> Bool? {
        guard hasSameEpoch(as: other) else { return nil }
        return sequence > other.sequence
    }
}

extension Watermark: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let watermark = Watermark(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a watermark of the form epoch:sequence, got \"\(raw)\"."
                ))
        }
        self = watermark
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
