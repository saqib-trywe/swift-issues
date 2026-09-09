/// A calendar day, with no time and no timezone.
///
/// A due date is a day, not an instant. Storing one as a timestamp means an
/// Issue due "Friday" renders as Thursday for a teammate one timezone west, so
/// this deliberately holds no `Date` and cannot be shifted by a formatter.
/// See CONTEXT.md and ticket 01.
public struct CivilDate: Hashable, Sendable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// `nil` for a malformed value or a day that does not exist. Deliberately
    /// strict about the shape: an RFC 3339 instant must not parse here, or the
    /// timezone bug this type prevents would return through the wire.
    public init?(wireValue: String) {
        let parts = wireValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// `nil` for a day that does not exist, so an invalid date is unrepresentable.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The value as it appears on the wire: `YYYY-MM-DD`, never an instant.
    public var wireValue: String {
        let m = month < 10 ? "0\(month)" : "\(month)"
        let d = day < 10 ? "0\(day)" : "\(day)"
        return "\(year)-\(m)-\(d)"
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        default: isLeapYear(year) ? 29 : 28
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}

extension CivilDate {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let date = CivilDate(wireValue: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Expected a calendar date as YYYY-MM-DD, got \"\(raw)\". "
                        + "Note that an RFC 3339 instant is deliberately not accepted."
                )
            )
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
