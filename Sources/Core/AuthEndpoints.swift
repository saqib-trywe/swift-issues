import Foundation

/// Credentials, sent exactly once to obtain a token.
///
/// This is the only place a password crosses any client, which is why it is a
/// named type rather than an inline dictionary: it should be greppable.
public struct LoginRequest: Codable, Sendable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

/// What a successful login returns.
///
/// The token exists in plaintext exactly once, here. The server stores only a
/// hash, so it cannot be recovered later — losing it means logging in again.
public struct LoginResponse: Codable, Sendable {
    public let token: String
    public let user: User

    public init(token: String, user: User) {
        self.token = token
        self.user = user
    }
}

/// Requests for obtaining and discarding a session.
public enum AuthEndpoints {

    public static func login(email: String, password: String) throws -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            path: "/api/v1/auth/login",
            headers: ["Content-Type": "application/json"],
            body: try JSONCoders.encoder.encode(LoginRequest(email: email, password: password)))
    }
}
