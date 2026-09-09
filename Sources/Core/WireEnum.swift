/// An enumeration that crosses the wire as a lowerCamelCase string and tolerates
/// values it does not recognise.
///
/// A self-hosted server can be upgraded well ahead of the clients in the field.
/// Strict decoding would let one server upgrade break sync for the entire
/// installed base at once, and coercing an unrecognised value to a default would
/// corrupt data on the way back up. Conformers therefore carry an `unknown` case
/// and preserve its payload verbatim. See ticket 06.
public protocol WireEnum: Codable, Hashable, Sendable {
    /// Never fails: an unrecognised value maps to the conformer's `unknown` case.
    init(wireValue: String)
    var wireValue: String { get }
}

extension WireEnum {
    public init(from decoder: any Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
