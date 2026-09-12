/// A field in a JSON Merge Patch body (RFC 7386).
///
/// Merge Patch distinguishes three states that Swift's `Optional` collapses into
/// two: a key that is absent (leave the field alone), a key whose value is `null`
/// (clear the field), and a key with a value (set it). Modelling that with `T?`
/// means either nothing can ever be cleared, or every patch wipes the fields it
/// did not mention. See ADR 0005.
public enum Patchable<Value> {
    /// The key was absent: leave the existing value alone.
    case unchanged
    /// The key was present and `null`: clear the field.
    case cleared
    /// The key was present with a value: set the field to it.
    case set(Value)

    /// Whether this says nothing at all.
    ///
    /// Available without `Value: Equatable`, so merge logic can ask the question
    /// for any payload type — the same reason `Settable` has it.
    public var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

extension Patchable: Equatable where Value: Equatable {}
extension Patchable: Sendable where Value: Sendable {}

extension Patchable: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = container.decodeNil() ? .cleared : .set(try container.decode(Value.self))
    }
}

extension Patchable: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unchanged:
            // `.unchanged` means "this key is absent", which only has meaning
            // inside a keyed container, where the overload below omits it.
            // Emitting `null` here would read as `.cleared` and silently wipe
            // the field.
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription:
                        "Patchable.unchanged has no representation outside a keyed container. "
                        + "Encoding it here would emit null, which means 'clear this field' "
                        + "rather than 'leave it alone'."
                )
            )
        case .cleared:
            try container.encodeNil()
        case .set(let value):
            try container.encode(value)
        }
    }
}

extension KeyedDecodingContainer {
    /// Shadows the synthesised `decode(_:forKey:)` so an absent key yields
    /// `.unchanged` instead of throwing `keyNotFound`.
    public func decode<Value: Decodable>(
        _ type: Patchable<Value>.Type,
        forKey key: Key
    ) throws -> Patchable<Value> {
        guard contains(key) else { return .unchanged }
        if try decodeNil(forKey: key) { return .cleared }
        return try Patchable<Value>(from: superDecoder(forKey: key))
    }
}

extension KeyedEncodingContainer {
    /// Shadows the synthesised `encode(_:forKey:)` so `.unchanged` omits the key
    /// entirely. Merge Patch semantics depend on the difference between an absent
    /// key and a `null` one, and the synthesised encoder always writes every
    /// property.
    public mutating func encode<Value: Encodable>(
        _ value: Patchable<Value>,
        forKey key: Key
    ) throws {
        switch value {
        case .unchanged:
            return
        case .cleared:
            try encodeNil(forKey: key)
        case .set(let wrapped):
            try encode(wrapped, forKey: key)
        }
    }
}
