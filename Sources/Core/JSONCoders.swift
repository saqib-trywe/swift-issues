import Foundation

/// The JSON encoder and decoder every surface uses.
///
/// The wire conventions from ticket 06 — camelCase keys, RFC 3339 instants with
/// an explicit `Z` and millisecond precision — are properties of the contract,
/// not of each call site. Constructing a bare `JSONEncoder` anywhere else would
/// silently produce a different format, so these are the shared ones.
///
/// Note `CivilDate` and the wire enums encode themselves and are unaffected by
/// any strategy set here.
public enum JSONCoders {

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Deterministic key order. JSON objects are unordered, so this changes
        // nothing semantically, but it makes payloads diffable and stops
        // byte-comparison tests failing on reordering alone.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(rfc3339Formatter.string(from: date))
        }
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Servers may omit fractional seconds; accept both forms.
            if let date = rfc3339Formatter.date(from: raw) { return date }
            if let date = rfc3339WholeSecondsFormatter.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an RFC 3339 instant, got \"\(raw)\"."
                )
            )
        }
        return decoder
    }()

    /// Formats an instant exactly as the body encoder does, so a query
    /// parameter and a payload never disagree about the format.
    public static func instantString(_ date: Date) -> String {
        rfc3339Formatter.string(from: date)
    }

    private static let rfc3339Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private static let rfc3339WholeSecondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
}
