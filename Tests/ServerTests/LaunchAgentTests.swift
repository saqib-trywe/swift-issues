import Foundation
import Testing

@testable import Server

/// The launchd job. Everything here is a detail that, if wrong, shows up only as
/// an agent that silently never starts.
@Suite("LaunchAgent")
struct LaunchAgentTests {

    private func job(home: String = "/Users/test") throws -> [String: Any] {
        let data = try LaunchAgent.plistData(home: URL(fileURLWithPath: home))
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return try #require(parsed as? [String: Any])
    }

    @Test("the plist is a plist")
    func plistParses() throws {
        let job = try job()
        #expect(job["Label"] as? String == "co.trywe.issues.server")
    }

    /// A home directory with an `&` or a quote in it would produce a document
    /// launchd refuses, if this were assembled as a string.
    @Test("an awkward home directory still produces a readable plist")
    func awkwardHomeDirectory() throws {
        let job = try job(home: "/Users/a & b's <mac>")
        let arguments = try #require(job["ProgramArguments"] as? [String])

        #expect(arguments.first?.contains("a & b's <mac>") == true)
    }

    @Test("the job runs the server out of the user's own bin")
    func runsTheInstalledBinary() throws {
        let arguments = try #require(try job()["ProgramArguments"] as? [String])

        #expect(arguments == ["/Users/test/.local/bin/issues-server", "serve"])
    }

    @Test("it starts at login and is kept running")
    func staysRunning() throws {
        let job = try job()

        #expect(job["RunAtLoad"] as? Bool == true)
        // A tracker that stops when it crashes is a tracker nobody trusts.
        #expect(job["KeepAlive"] as? Bool == true)
    }

    /// `Background` is I/O-throttled, which is the wrong trade for something
    /// answering requests from the apps on this machine.
    @Test("the process class is not the throttled one")
    func processClassIsNotThrottled() throws {
        #expect(try job()["ProcessType"] as? String == "Adaptive")
    }

    /// Ticket 09: under launchd there is no terminal, so without a log destination
    /// the first-run setup token would be unreachable and setup impossible.
    @Test("output goes somewhere an admin can read it")
    func outputIsCaptured() throws {
        let job = try job()

        let out = try #require(job["StandardOutPath"] as? String)
        #expect(out == "/Users/test/Library/Logs/Issues/server.log")
        // Both streams, or the token lands in whichever one it was not written to.
        #expect(job["StandardErrorPath"] as? String == out)
    }

    @Test("the agent and the uninstaller agree on where things are")
    func pathsAgree() {
        let home = URL(fileURLWithPath: "/Users/test")

        #expect(
            LaunchAgent.plistURL(home: home).path
                == "/Users/test/Library/LaunchAgents/co.trywe.issues.server.plist")
        #expect(LaunchAgent.serviceTarget(uid: 501) == "gui/501/co.trywe.issues.server")
        #expect(LaunchAgent.domainTarget(uid: 501) == "gui/501")
    }
}
