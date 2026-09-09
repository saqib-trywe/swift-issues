import Core
import Foundation

/// An in-memory `HTTPTransport` that records what it was asked for.
///
/// Recording is what lets a test assert the request a call actually produced,
/// end-to-end through the client, rather than only against an endpoint builder.
/// The responder form lets a test vary by request, which the sync harness in
/// ticket 13 needs.
///
/// Linked only by test targets; never shipped.
public actor FakeTransport: HTTPTransport {
    private let responder: @Sendable (HTTPRequest) throws -> HTTPResponse

    /// Every request received, in order.
    public private(set) var requests: [HTTPRequest] = []

    public init(_ responder: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.responder = responder
    }

    /// Always answers the same way.
    public static func returning(
        status: Int,
        json: String = "",
        headers: [String: String] = [:]
    ) -> FakeTransport {
        FakeTransport { _ in
            HTTPResponse(status: status, headers: headers, body: Data(json.utf8))
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try responder(request)
    }
}
