import Foundation

/// Sends requests built by the endpoint namespaces and interprets what comes back.
///
/// Deals in paths, not URLs: resolving a path against a host is the transport
/// adapter's job, so nothing here needs a base URL and the adapter keeps no logic
/// of its own. See ticket 13.
public struct APIClient: Sendable {
    private let transport: any HTTPTransport
    private let token: @Sendable () async -> String?

    /// The token is read per request rather than captured once, because a session
    /// can be replaced by re-login while a client instance lives on.
    public init(
        transport: any HTTPTransport,
        token: @escaping @Sendable () async -> String?
    ) {
        self.transport = transport
        self.token = token
    }

    /// Sends a request and decodes its response.
    public func send<T: Decodable>(_ request: HTTPRequest, expecting: T.Type) async throws -> T {
        try await perform(request).decoded(expecting)
    }

    /// Sends a request that carries no response value, still checking the status.
    public func send(_ request: HTTPRequest) async throws {
        try await perform(request).discardingValue()
    }

    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        request.headers["Accept"] = "application/json"
        // Omitted entirely when absent: `/health` is unauthenticated, and an
        // empty Authorization header is not the same as no header.
        if let token = await token() {
            request.headers["Authorization"] = "Bearer \(token)"
        }
        return try await transport.send(request)
    }
}
