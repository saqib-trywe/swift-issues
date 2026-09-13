import Foundation

/// A JSON-RPC 2.0 message, as MCP uses it.
///
/// Hand-rolled rather than taken as a dependency: the surface needed here is small
/// and is pure request-in/response-out, which makes it testable the same way
/// everything else in this project is. The cost, stated plainly, is that it is
/// verified against the specification rather than against a real client.
public struct RPCRequest: Sendable {
    /// Absent for a notification, which expects no reply.
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue

    public var isNotification: Bool { id == nil }
}

public struct RPCError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String

    /// The codes the specification fixes.
    public static func parseError(_ message: String) -> RPCError { .init(code: -32_700, message: message) }
    public static func invalidRequest(_ message: String) -> RPCError {
        .init(code: -32_600, message: message)
    }
    public static func methodNotFound(_ method: String) -> RPCError {
        .init(code: -32_601, message: "Unknown method '\(method)'.")
    }
    public static func internalError(_ message: String) -> RPCError { .init(code: -32_603, message: message) }
}

/// A minimal JSON tree.
///
/// MCP payloads are arbitrary JSON and Swift's `Codable` wants concrete types, so
/// an explicit value type is simpler than fighting `Any` across a `Sendable`
/// boundary.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        if case .string(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers are written as integers: a `limit` of `25.0` in a log is
            // needless noise, and some clients are fussy about it.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Parsing and rendering the wire format.
public enum JSONRPC {

    public static func parse(_ line: String) throws -> RPCRequest {
        guard let data = line.data(using: .utf8), !data.isEmpty else {
            throw RPCError.parseError("Empty message.")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RPCError.parseError("Not valid JSON.")
        }

        guard value["jsonrpc"]?.stringValue == "2.0" else {
            throw RPCError.invalidRequest("Expected \"jsonrpc\": \"2.0\".")
        }
        guard let method = value["method"]?.stringValue else {
            throw RPCError.invalidRequest("Missing \"method\".")
        }

        // A request with no id is a notification and must not be answered — replying
        // to one is a protocol violation that confuses a client's pending table.
        let id = value["id"].flatMap { $0 == .null ? nil : $0 }
        return RPCRequest(id: id, method: method, params: value["params"] ?? .object([:]))
    }

    public static func response(id: JSONValue, result: JSONValue) -> String {
        render(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    public static func failure(id: JSONValue?, error: RPCError) -> String {
        render([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object(["code": .number(Double(error.code)), "message": .string(error.message)]),
        ])
    }

    static func render(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        // Sorted so a response is diffable between runs, and never pretty-printed:
        // stdio framing is one message per line, and a newline inside would split it.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(fields)) else {
            return
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not encode a reply."}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
