import Foundation

/// The executable's shell.
///
/// Deliberately minimal, like `URLSessionTransport` on the client side: anything
/// worth testing belongs in this library, not in the entry point.
public enum ServerEntryPoint {
    public static func main() async throws {
        fatalError("Not implemented yet — the HTTP application is the next slice.")
    }
}
