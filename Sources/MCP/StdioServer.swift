import Core
import Credentials
import Foundation

/// The stdio loop.
///
/// One JSON message per line, which is what MCP's stdio transport specifies. The
/// only part of this module that touches the outside world; everything it calls is
/// a pure function.
public enum StdioServer {

    public static func run() async {
        let session = makeSession(environment: ProcessInfo.processInfo.environment)

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let reply = await session.handle(line) else { continue }
            print(reply)
            // Flushed every message: a host waiting on a reply that is sitting in a
            // buffer looks like a hung server.
            fflush(stdout)
        }
    }

    /// Builds a session from the environment.
    ///
    /// `ISSUES_URL` and `ISSUES_TOKEN`, exactly as the CLI uses them (ticket 12) —
    /// and falling back to the CLI's own stored credential, so an agent configured
    /// on a machine where somebody has already run `issues auth login` works with no
    /// extra setup.
    public static func makeSession(
        environment: [String: String],
        credentials: any CredentialStore = KeychainCredentialStore()
    ) -> MCPSession {
        guard let raw = environment["ISSUES_URL"], !raw.isEmpty,
            let url = URL(string: raw), url.scheme != nil
        else {
            return MCPSession(
                configurationFailure:
                    "This server has no ISSUES_URL set. Add it to the MCP server's "
                    + "environment, along with an ISSUES_TOKEN from `issues auth token create`.")
        }

        let token: String? =
            environment["ISSUES_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (try? credentials.token(forServer: originKey(for: url)))

        guard let token else {
            return MCPSession(
                configurationFailure:
                    "This server has no ISSUES_TOKEN set, and no stored credential for "
                    + "\(originKey(for: url)). Create one with "
                    + "`issues auth token create --kind agent --label <name>`.")
        }

        return MCPSession(
            runner: ToolRunner(
                client: APIClient(
                    transport: URLSessionTransport(baseURL: url), token: { token })))
    }

    /// Credentials are keyed by origin, matching the CLI, so a trailing slash does
    /// not produce a second invisible credential.
    static func originKey(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}
