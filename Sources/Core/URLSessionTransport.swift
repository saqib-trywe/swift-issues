import Foundation

/// Errors from mapping a request onto a URL.
public enum TransportError: Error, Hashable, Sendable {
    /// The base URL and path could not be composed into a valid URL.
    case invalidURL(base: String, path: String)
    /// The response was not an HTTP response.
    case notHTTP
}

extension URLRequest {
    /// Maps a `HTTPRequest` onto Foundation, resolving its path against a base URL.
    ///
    /// This is where the adapter's only real logic lives — URL composition and
    /// query encoding — so it is a pure function rather than something buried
    /// inside a network call.
    public init(_ request: HTTPRequest, relativeTo base: URL) throws {
        // `appending(path:)` handles a trailing slash on the base and a leading
        // slash on the path without doubling up, and preserves a path prefix when
        // the API is served under one behind a proxy.
        var components = URLComponents(
            url: base.appending(path: request.path),
            resolvingAgainstBaseURL: false
        )
        if !request.query.isEmpty {
            components?.queryItems = request.query.map {
                URLQueryItem(name: $0.name, value: $0.value)
            }
        }
        guard let url = components?.url else {
            throw TransportError.invalidURL(base: base.absoluteString, path: request.path)
        }

        self.init(url: url)
        httpMethod = request.method
        httpBody = request.body
        for (name, value) in request.headers {
            setValue(value, forHTTPHeaderField: name)
        }
    }
}

extension HTTPResponse {
    /// Maps a Foundation response back onto a value.
    public init(_ response: HTTPURLResponse, body: Data) {
        self.init(
            status: response.statusCode,
            headers: Dictionary(
                uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value in
                    guard let name = key as? String else { return nil }
                    return (name, String(describing: value))
                }),
            body: body
        )
    }
}

/// The real transport.
///
/// Deliberately almost empty: the mappings above are pure and tested, so all that
/// is left here is handing a `URLRequest` to `URLSession`. That was the point of
/// making the transport a one-method protocol. See ticket 13.
public struct URLSessionTransport: HTTPTransport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: URLRequest(request, relativeTo: baseURL))
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
        return HTTPResponse(http, body: data)
    }
}
