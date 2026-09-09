import Foundation

/// An RFC 9457 problem details document.
///
/// The error format for every endpoint (ticket 06). `type` is a stable slug
/// clients may branch on; `title` and `detail` are for humans. `errors` is the
/// extension member carrying field-level validation failures.
public struct Problem: Hashable, Sendable, Codable {
    public let type: String
    public let title: String
    public let status: Int
    public let detail: String?
    public let errors: [ValidationFailure]?

    public init(
        type: String,
        title: String,
        status: Int,
        detail: String? = nil,
        errors: [ValidationFailure]? = nil
    ) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.errors = errors
    }
}

/// A failed API call, classified by what the caller can do about it.
public enum APIError: Error, Hashable, Sendable {
    /// 401. The session is not valid. Per ADR 0006 this must preserve a pending
    /// sync queue and prompt re-authentication, never quarantine the writes.
    case unauthenticated(Problem?)
    /// 403. The session is valid but this is not permitted.
    case forbidden(Problem?)
    /// 404. No such id.
    case notFound(Problem?)
    /// 410. It existed and is gone — deliberately distinct from 404.
    case gone(Problem?)
    /// 409. A conflicting record already exists, e.g. re-creating an id with
    /// different content.
    case conflict(Problem?)
    /// 400 or 422. Malformed or invalid; `errors` carries the field failures.
    case invalidRequest(Problem?)
    /// 429. `retryAfter` is in seconds and must be honoured rather than retried
    /// through (ticket 12).
    case rateLimited(retryAfter: TimeInterval?, problem: Problem?)
    /// 5xx.
    case server(status: Int, problem: Problem?)
    /// Any other status.
    case unexpectedStatus(Int)
}

extension HTTPResponse {

    /// Interprets a response as a decoded value, or throws a classified error.
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try throwIfFailure()
        return try JSONCoders.decoder.decode(type, from: body)
    }

    /// Interprets a response that carries no value.
    public func discardingValue() throws {
        try throwIfFailure()
    }

    /// Static form, so tests and call sites read the same way.
    public static func value<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        try response.decoded(type)
    }

    private func throwIfFailure() throws {
        guard !(200..<300).contains(status) else { return }

        // A non-problem+json body (an HTML error page from a proxy, say) must not
        // mask the status, so a failed decode leaves `problem` nil.
        let problem = try? JSONCoders.decoder.decode(Problem.self, from: body)

        switch status {
        case 401: throw APIError.unauthenticated(problem)
        case 403: throw APIError.forbidden(problem)
        case 404: throw APIError.notFound(problem)
        case 409: throw APIError.conflict(problem)
        case 410: throw APIError.gone(problem)
        case 400, 422: throw APIError.invalidRequest(problem)
        case 429:
            let header = headers.first { $0.key.lowercased() == "retry-after" }?.value
            throw APIError.rateLimited(retryAfter: header.flatMap(TimeInterval.init), problem: problem)
        case 500..<600: throw APIError.server(status: status, problem: problem)
        default: throw APIError.unexpectedStatus(status)
        }
    }
}
