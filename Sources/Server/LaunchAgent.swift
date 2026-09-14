import Foundation

/// The launchd job that keeps the server running (ticket 09).
///
/// A **LaunchAgent**, not a LaunchDaemon: the install is rootless and per-user, so
/// the job belongs to the login session that owns the data. A daemon would run as
/// root and need a system-wide data directory, which is the deployment model ADR
/// 0010 rejected.
///
/// The plist is built here rather than in the installer's shell script so that it
/// is generated once, tested, and shared with `uninstall` — which has to name the
/// same label and the same paths or it silently leaves a job behind.
public enum LaunchAgent {

    public static let label = "co.trywe.issues.server"

    public static func plistURL(home: URL) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// Ticket 09: the bootstrap token printed on first run needs a destination an
    /// admin can reach without having run the binary interactively. Under launchd
    /// there is no terminal to print to, so first-run setup would be impossible
    /// without this.
    public static func logURL(home: URL) -> URL {
        home.appending(path: "Library/Logs/Issues/server.log")
    }

    public static func binaryURL(home: URL) -> URL {
        home.appending(path: ".local/bin/issues-server")
    }

    /// The launchd domain a per-user agent lives in.
    public static func domainTarget(uid: uid_t) -> String { "gui/\(uid)" }

    public static func serviceTarget(uid: uid_t) -> String { "gui/\(uid)/\(label)" }

    /// The job description, as a property list.
    ///
    /// Serialised by `PropertyListSerialization` rather than assembled as a string:
    /// a home directory containing an `&` or a quote would produce a plist that
    /// launchd refuses, and the failure would appear as an agent that simply never
    /// starts.
    public static func plistData(home: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: job(home: home), format: .xml, options: 0)
    }

    static func job(home: URL) -> [String: Any] {
        [
            "Label": label,
            // `serve` explicitly, even though it is the default subcommand. A plist
            // is read by people diagnosing an agent that will not start, and one
            // that names what it runs answers a question the bare path does not.
            "ProgramArguments": [binaryURL(home: home).path, "serve"],
            "RunAtLoad": true,
            // A tracker that stops when it crashes is a tracker nobody trusts.
            // launchd throttles restarts to once every ten seconds, so a genuinely
            // broken build cannot spin.
            "KeepAlive": true,
            // Not `Background`: that class is I/O-throttled, which is the wrong
            // trade for something answering requests from the apps on this machine.
            "ProcessType": "Adaptive",
            "StandardOutPath": logURL(home: home).path,
            "StandardErrorPath": logURL(home: home).path,
        ]
    }
}
