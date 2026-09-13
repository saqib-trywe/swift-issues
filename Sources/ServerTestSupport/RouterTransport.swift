import Core
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore

/// Dispatches a Core `HTTPRequest` into the real router.
///
/// The same seam the CLI tests use. It is what makes these sync tests real: the
/// client engine runs against real routing, real persistence and the real push and
/// pull services, with no socket and no canned responses.
public struct RouterTransport: HTTPTransport {
    public let client: any TestClientProtocol

    public init(client: any TestClientProtocol) { self.client = client }

    public func send(_ request: Core.HTTPRequest) async throws -> Core.HTTPResponse {
        var components = URLComponents()
        components.path = request.path
        if !request.query.isEmpty {
            components.queryItems = request.query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }

        var headers = HTTPFields()
        for (name, value) in request.headers {
            guard let field = HTTPField.Name(name) else { continue }
            headers[field] = value
        }

        return try await client.execute(
            uri: components.string ?? request.path,
            method: .init(rawValue: request.method) ?? .get,
            headers: headers,
            body: request.body.map { ByteBuffer(data: $0) }
        ) { response in
            var received: [String: String] = [:]
            for field in response.headers { received[field.name.canonicalName] = field.value }
            return Core.HTTPResponse(
                status: Int(response.status.code),
                headers: received,
                body: Data(buffer: response.body))
        }
    }
}
