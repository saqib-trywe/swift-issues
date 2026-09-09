import Foundation

/// An HTTP request, described as a value so it can be asserted without a network.
public struct HTTPRequest: Hashable, Sendable {
    public var method: String
    public var path: String
    public var query: [(name: String, value: String)]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: String,
        path: String,
        query: [(name: String, value: String)] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.headers == rhs.headers
            && lhs.body == rhs.body
            && lhs.query.map { [$0.name, $0.value] } == rhs.query.map { [$0.name, $0.value] }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(method)
        hasher.combine(path)
        hasher.combine(body)
    }
}

/// An HTTP response, described as a value for the same reason.
public struct HTTPResponse: Hashable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The one seam between the API client and the network.
///
/// Narrow on purpose: request building and response interpretation are pure logic
/// and hold the bugs, so they are tested directly, and the `URLSession` adapter
/// has nothing left in it to get wrong. See ticket 13.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
