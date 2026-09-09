/// A non-nullable field in a JSON Merge Patch body.
///
/// The counterpart to `Patchable`, for fields that cannot be cleared. `title`,
/// `description`, `status` and `priority` always have a value, so a `.cleared`
/// case would let a caller express a patch only the server could reject. Two
/// types make an invalid patch unrepresentable instead. See ADR 0005.
public enum Settable<Value> {
    /// The key is absent: leave the existing value alone.
    case unchanged
    /// The key is present with a value: set the field to it.
    case set(Value)

    public var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

extension Settable: Equatable where Value: Equatable {}
extension Settable: Sendable where Value: Sendable {}

extension Settable: Decodable where Value: Decodable {
    /// A null has nowhere to go — there is no `.cleared` — so it fails here
    /// rather than being silently read as `.unchanged`, which would swallow a
    /// caller's intent to clear a field that cannot be cleared.
    public init(from decoder: any Decoder) throws {
        self = .set(try decoder.singleValueContainer().decode(Value.self))
    }
}

extension Settable: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .unchanged:
            // As with `Patchable.unchanged`, "absent" only has meaning inside a
            // keyed container, where the overload below omits the key. Emitting
            // anything here would be a value the server would act on.
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription:
                        "Settable.unchanged has no representation outside a keyed container."
                )
            )
        case .set(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
}

extension KeyedEncodingContainer {
    /// Shadows the synthesised `encode(_:forKey:)` so `.unchanged` omits the key.
    public mutating func encode<Value: Encodable>(
        _ value: Settable<Value>,
        forKey key: Key
    ) throws {
        if case .set(let wrapped) = value {
            try encode(wrapped, forKey: key)
        }
    }
}

extension KeyedDecodingContainer {
    /// Shadows the synthesised `decode(_:forKey:)` so an absent key is
    /// `.unchanged` rather than a `keyNotFound` error.
    public func decode<Value: Decodable>(
        _ type: Settable<Value>.Type,
        forKey key: Key
    ) throws -> Settable<Value> {
        guard contains(key) else { return .unchanged }
        return .set(try decode(Value.self, forKey: key))
    }
}
