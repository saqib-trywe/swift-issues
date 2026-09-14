import Core
import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Server

/// A context that remembers what a command said and did.
final class CommandRecorder: Sendable {
    struct State {
        var out: [String] = []
        var err: [String] = []
        var secrets: [String] = []
        var prompts: [String] = []
        var processes: [[String]] = []
        var served = false
    }

    let state = Mutex(State())

    init(secrets: [String] = []) {
        state.withLock { $0.secrets = secrets }
    }

    var output: String { state.withLock { $0.out.joined(separator: "\n") } }
    var errors: String { state.withLock { $0.err.joined(separator: "\n") } }
    var prompts: [String] { state.withLock { $0.prompts } }
    var processes: [[String]] { state.withLock { $0.processes } }
    var served: Bool { state.withLock { $0.served } }

    func context(environment: [String: String] = [:]) -> ServerContext {
        ServerContext(
            environment: environment,
            print: { line in self.state.withLock { $0.out.append(line) } },
            printError: { line in self.state.withLock { $0.err.append(line) } },
            readSecret: { prompt in
                try self.state.withLock { state in
                    state.prompts.append(prompt)
                    guard !state.secrets.isEmpty else {
                        throw AdminOperations.Failure.rejected(["no secret queued"])
                    }
                    return state.secrets.removeFirst()
                }
            },
            serve: { self.state.withLock { $0.served = true } },
            runProcess: { arguments in
                self.state.withLock { $0.processes.append(arguments) }
                return 0
            },
            hasher: .testing)
    }
}

@Suite("Server commands")
struct ServerCommandTests {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "issues-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func seed(at url: URL, email: String = "saqib@example.com") throws -> AppDatabase {
        let database = try AppDatabase.open(at: url)
        try UserRepository(database: database).save(.fixture(email: email))
        return database
    }

    // MARK: Dispatch

    /// launchd runs the binary with no arguments. A plist naming a subcommand is one
    /// more thing to get wrong, so the bare invocation has to serve.
    @Test("no arguments serves")
    func noArgumentsServes() async throws {
        let recorder = CommandRecorder()
        let code = await ServerCLI.run(arguments: [], context: recorder.context())

        #expect(code == 0)
        #expect(recorder.served)
    }

    @Test("an unknown subcommand is a usage error")
    func unknownSubcommand() async throws {
        let recorder = CommandRecorder()
        let code = await ServerCLI.run(arguments: ["restart-everything"], context: recorder.context())

        #expect(code == 2)
        #expect(!recorder.errors.isEmpty)
        #expect(!recorder.served)
    }

    /// Help is not a failure, and piping it into a pager should work.
    @Test("help goes to stdout at zero")
    func helpIsNotAFailure() async throws {
        let recorder = CommandRecorder()
        let code = await ServerCLI.run(arguments: ["--help"], context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.contains("backup"))
        #expect(recorder.output.contains("restore"))
        #expect(recorder.errors.isEmpty)
    }

    @Test("version prints a version")
    func versionPrints() async throws {
        let recorder = CommandRecorder()
        let code = await ServerCLI.run(arguments: ["version"], context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output == ServerCLI.version)
    }

    // MARK: Backup

    @Test("backup writes a file and says where")
    func backupWritesAFile() async throws {
        let directory = try scratch()
        let source = directory.appending(path: "issues.sqlite")
        let database = try seed(at: source)
        let destination = directory.appending(path: "out.sqlite")

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["backup", "--database", source.path, destination.path],
            context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.contains(destination.path))
        #expect(try Maintenance.inspect(destination).userCount == 1)
        try database.writer.close()
    }

    @Test("backing up over an existing file fails with the reason")
    func backupRefusesToOverwrite() async throws {
        let directory = try scratch()
        let source = directory.appending(path: "issues.sqlite")
        let database = try seed(at: source)
        let destination = directory.appending(path: "out.sqlite")
        try Data("earlier".utf8).write(to: destination)

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["backup", "--database", source.path, destination.path],
            context: recorder.context())

        #expect(code == 1)
        #expect(recorder.errors.contains("already exists"))
        #expect(try Data(contentsOf: destination) == Data("earlier".utf8))
        try database.writer.close()
    }

    // MARK: Inspect

    @Test("inspect describes a backup without restoring it")
    func inspectDescribes() async throws {
        let directory = try scratch()
        let source = directory.appending(path: "issues.sqlite")
        let database = try seed(at: source)
        try database.writer.close()
        let backup = directory.appending(path: "out.sqlite")
        try Maintenance.backup(databaseAt: source, to: backup)

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(arguments: ["inspect", backup.path], context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.contains("users     1"))
        #expect(recorder.output.contains(try Maintenance.inspect(backup).epoch))
    }

    /// Said before a restore rather than discovered during one.
    @Test("inspect warns when a backup predates this binary")
    func inspectWarnsAboutOlderSchema() async throws {
        let directory = try scratch()
        let old = directory.appending(path: "old.sqlite")
        try MaintenanceTests.makeOlderSchema(at: old)

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(arguments: ["inspect", old.path], context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.contains("older than this binary"))
    }

    @Test("inspecting something that is not a backup fails")
    func inspectRejectsJunk() async throws {
        let junk = try scratch().appending(path: "notes.txt")
        try Data("hello".utf8).write(to: junk)

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(arguments: ["inspect", junk.path], context: recorder.context())

        #expect(code == 1)
        #expect(recorder.errors.contains("not an Issues database"))
    }

    // MARK: Restore

    @Test("restoring over an existing database needs --force")
    func restoreNeedsForce() async throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        let source = try seed(at: backup, email: "from-backup@example.com")
        try source.writer.close()
        let target = directory.appending(path: "live.sqlite")
        let live = try seed(at: target, email: "already-here@example.com")
        try live.writer.close()

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["restore", "--database", target.path, backup.path],
            context: recorder.context())

        #expect(code == 1)
        #expect(recorder.errors.contains("--force"))
        #expect(try Maintenance.inspect(target).userCount == 1)
    }

    /// The consequence an operator has to know about, stated every time: silence
    /// here is how a fleet of clients diverges without an error.
    @Test("a restore says that clients will resync")
    func restoreExplainsTheResync() async throws {
        let directory = try scratch()
        let backup = directory.appending(path: "backup.sqlite")
        let source = try seed(at: backup, email: "from-backup@example.com")
        try source.writer.close()
        let target = directory.appending(path: "live.sqlite")
        let live = try seed(at: target, email: "already-here@example.com")
        try live.writer.close()

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["restore", "--database", target.path, "--force", backup.path],
            context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.contains("full-resync"))
        #expect(recorder.output.contains("epoch"))
        // And where the data that was there went.
        #expect(recorder.output.contains("superseded-"))
    }

    // MARK: Admin

    @Test("reset-password sets a password that verifies")
    func resetPasswordWorks() async throws {
        let directory = try scratch()
        let url = directory.appending(path: "issues.sqlite")
        let database = try seed(at: url, email: "locked-out@example.com")
        try database.writer.close()

        let recorder = CommandRecorder(secrets: ["a-new-password", "a-new-password"])
        let code = await ServerCLI.run(
            arguments: ["admin", "reset-password", "--database", url.path, "locked-out@example.com"],
            context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.contains("sessions have been ended"))

        let reopened = try AppDatabase.open(at: url)
        let stored = try #require(
            try UserRepository(database: reopened).credentials(forEmail: "locked-out@example.com"))
        #expect(try PasswordHasher.verify("a-new-password", against: stored.passwordHash))
        try reopened.writer.close()
    }

    /// Prompts go to stderr, so `issues-server ... > file` does not capture them.
    @Test("the password prompt names the account")
    func promptNamesTheAccount() async throws {
        let url = try scratch().appending(path: "issues.sqlite")
        let database = try seed(at: url, email: "saqib@example.com")
        try database.writer.close()

        let recorder = CommandRecorder(secrets: ["a-new-password", "a-new-password"])
        _ = await ServerCLI.run(
            arguments: ["admin", "reset-password", "--database", url.path, "saqib@example.com"],
            context: recorder.context())

        #expect(recorder.prompts.first?.contains("saqib@example.com") == true)
        #expect(recorder.prompts.count == 2)
    }

    @Test("a mistyped repeat changes nothing")
    func mistypedRepeatChangesNothing() async throws {
        let url = try scratch().appending(path: "issues.sqlite")
        let database = try seed(at: url)
        let users = UserRepository(database: database)
        let existing = try #require(try users.find(email: "saqib@example.com"))
        try users.setPassword(try PasswordHasher.testing.hash("the-old-one"), for: existing.id)
        try database.writer.close()

        let recorder = CommandRecorder(secrets: ["first-attempt", "second-attempt"])
        let code = await ServerCLI.run(
            arguments: ["admin", "reset-password", "--database", url.path, "saqib@example.com"],
            context: recorder.context())

        #expect(code == 2)
        #expect(recorder.errors.contains("do not match"))

        let reopened = try AppDatabase.open(at: url)
        let stored = try #require(
            try UserRepository(database: reopened).credentials(forEmail: "saqib@example.com"))
        #expect(try PasswordHasher.verify("the-old-one", against: stored.passwordHash))
        try reopened.writer.close()
    }

    @Test("resetting a password for nobody says so")
    func resetPasswordUnknownUser() async throws {
        let url = try scratch().appending(path: "issues.sqlite")
        let database = try seed(at: url)
        try database.writer.close()

        let recorder = CommandRecorder(secrets: ["a-new-password", "a-new-password"])
        let code = await ServerCLI.run(
            arguments: ["admin", "reset-password", "--database", url.path, "ghost@example.com"],
            context: recorder.context())

        #expect(code == 1)
        #expect(recorder.errors.contains("ghost@example.com"))
    }

    @Test("a password that is too short is refused here too")
    func shortPasswordRefused() async throws {
        let url = try scratch().appending(path: "issues.sqlite")
        let database = try seed(at: url)
        try database.writer.close()

        let recorder = CommandRecorder(secrets: ["short", "short"])
        let code = await ServerCLI.run(
            arguments: ["admin", "reset-password", "--database", url.path, "saqib@example.com"],
            context: recorder.context())

        #expect(code == 1)
        #expect(recorder.errors.lowercased().contains("at least"))
    }

    // MARK: Config

    @Test("config validate reports a good file")
    func configValidateAccepts() async throws {
        let file = try scratch().appending(path: "config.toml")
        try Data("host = \"0.0.0.0\"\nport = 9000\n".utf8).write(to: file)

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["config", "validate", "--file", file.path], context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.contains("0.0.0.0:9000"))
    }

    @Test("config validate rejects a typo rather than starting with it")
    func configValidateRejects() async throws {
        let file = try scratch().appending(path: "config.toml")
        try Data("prot = 9000\n".utf8).write(to: file)

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["config", "validate", "--file", file.path], context: recorder.context())

        #expect(code == 1)
        #expect(recorder.errors.contains("prot"))
    }

    /// A supported setting, never a silent one.
    @Test("config validate warns about plaintext tokens")
    func configValidateWarnsAboutInsecure() async throws {
        let file = try scratch().appending(path: "config.toml")
        try Data("allowInsecure = true\n".utf8).write(to: file)

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["config", "validate", "--file", file.path], context: recorder.context())

        #expect(code == 0)
        #expect(recorder.output.lowercased().contains("cleartext"))
    }

    // MARK: Install

    @Test("install-agent writes a plist and loads it")
    func installAgentWritesAndLoads() async throws {
        let home = try scratch()
        let recorder = CommandRecorder()

        let code = await ServerCLI.run(
            arguments: ["install-agent"], context: recorder.context(environment: ["HOME": home.path]))

        #expect(code == 0)
        let plist = LaunchAgent.plistURL(home: home)
        #expect(FileManager.default.fileExists(atPath: plist.path))
        #expect(recorder.processes.last?.first == "launchctl")
        #expect(recorder.processes.last?.contains("bootstrap") == true)
        #expect(recorder.processes.last?.contains(plist.path) == true)
    }

    /// launchd does not create the parent of `StandardOutPath`, and a job whose log
    /// path is unwritable fails to spawn with nowhere to say so.
    @Test("install-agent creates the log directory")
    func installAgentCreatesLogDirectory() async throws {
        let home = try scratch()
        let recorder = CommandRecorder()

        _ = await ServerCLI.run(
            arguments: ["install-agent"], context: recorder.context(environment: ["HOME": home.path]))

        let logs = LaunchAgent.logURL(home: home).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(recorder.output.contains(LaunchAgent.logURL(home: home).path))
    }

    /// Re-running the installer is an upgrade. Bootstrapping over a job that is
    /// already loaded fails, which would leave the old binary running and the
    /// installer reporting success.
    @Test("install-agent unloads an existing job before loading the new one")
    func installAgentIsIdempotent() async throws {
        let home = try scratch()
        let recorder = CommandRecorder()

        _ = await ServerCLI.run(
            arguments: ["install-agent"], context: recorder.context(environment: ["HOME": home.path]))

        let calls = recorder.processes
        #expect(calls.count == 2)
        #expect(calls.first?.contains("bootout") == true)
        #expect(calls.last?.contains("bootstrap") == true)
    }

    /// An agent that did not load must not be reported as installed: the operator
    /// would go looking for a server that is not running.
    @Test("a refused load is a failure, and says where the plist is")
    func refusedLoadIsAFailure() async throws {
        let home = try scratch()
        let recorder = CommandRecorder()
        var context = recorder.context(environment: ["HOME": home.path])
        context.runProcess = { arguments in arguments.contains("bootstrap") ? 5 : 0 }

        let code = await ServerCLI.run(arguments: ["install-agent"], context: context)

        #expect(code == 2)
        #expect(recorder.errors.contains(LaunchAgent.plistURL(home: home).path))
    }

    // MARK: Uninstall

    @Test("uninstall removes the agent and keeps the data")
    func uninstallKeepsData() async throws {
        let home = try scratch()
        let agents = home.appending(path: "Library/LaunchAgents")
        let bin = home.appending(path: ".local/bin")
        let data = home.appending(path: "Library/Application Support/Issues")
        for directory in [agents, bin, data] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let plist = agents.appending(path: "co.trywe.issues.server.plist")
        let binary = bin.appending(path: "issues-server")
        try Data("<plist/>".utf8).write(to: plist)
        try Data("binary".utf8).write(to: binary)
        try Data("db".utf8).write(to: data.appending(path: "issues.sqlite"))

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["uninstall"], context: recorder.context(environment: ["HOME": home.path]))

        #expect(code == 0)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(!FileManager.default.fileExists(atPath: binary.path))
        // Deleting somebody's issue tracker as a side effect of removing software
        // is hostile.
        #expect(FileManager.default.fileExists(atPath: data.appending(path: "issues.sqlite").path))
        #expect(recorder.output.contains(data.path))
    }

    /// The agent is unloaded before its plist goes, or launchd is left supervising a
    /// binary that is no longer there.
    @Test("uninstall unloads the agent first")
    func uninstallUnloadsFirst() async throws {
        let home = try scratch()
        let recorder = CommandRecorder()
        _ = await ServerCLI.run(
            arguments: ["uninstall"], context: recorder.context(environment: ["HOME": home.path]))

        let launched = try #require(recorder.processes.first)
        #expect(launched.first == "launchctl")
        #expect(launched.contains { $0.contains("co.trywe.issues.server") })
    }

    @Test("purge deletes the data, for people who mean it")
    func purgeDeletesData() async throws {
        let home = try scratch()
        let data = home.appending(path: "Library/Application Support/Issues")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: data.appending(path: "issues.sqlite"))

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["uninstall", "--purge"],
            context: recorder.context(environment: ["HOME": home.path]))

        #expect(code == 0)
        #expect(!FileManager.default.fileExists(atPath: data.path))
        #expect(recorder.output.contains("Purged"))
    }

    // MARK: Where a command looks when it is not told

    /// `$HOME` has been ignored twice in this project, once writing a config file
    /// and once a whole database into the operator's real home. A command given no
    /// path must resolve it from the environment it was handed.
    @Test("a command with no --database uses the install under $HOME")
    func defaultDatabasePath() async throws {
        let home = try scratch()
        let recorder = CommandRecorder()

        let code = await ServerCLI.run(
            arguments: ["backup", home.appending(path: "out.sqlite").path],
            context: recorder.context(environment: ["HOME": home.path]))

        #expect(code == 1)
        #expect(recorder.errors.contains(home.path))
        #expect(recorder.errors.contains("Library/Application Support/Issues/issues.sqlite"))
    }

    @Test("config validate with no --file uses the install under $HOME")
    func defaultConfigPath() async throws {
        let home = try scratch()
        let directory = home.appending(path: "Library/Application Support/Issues")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("port = 9100\n".utf8).write(to: directory.appending(path: "config.toml"))

        let recorder = CommandRecorder()
        let code = await ServerCLI.run(
            arguments: ["config", "validate"],
            context: recorder.context(environment: ["HOME": home.path]))

        #expect(code == 0)
        #expect(recorder.output.contains(":9100"))
    }

    // MARK: Byte sizes

    @Test(
        "byte counts read as sizes",
        arguments: [
            (0, "0 bytes"), (512, "512 bytes"), (1024, "1.0 KB"),
            (1_572_864, "1.5 MB"), (1_073_741_824, "1.0 GB"),
        ])
    func byteSizes(bytes: Int, expected: String) {
        #expect(ByteSize.describe(bytes) == expected)
    }
}

/// The host-side recovery path, on its own.
@Suite("Admin operations")
struct AdminOperationTests {

    private func database(email: String = "saqib@example.com", active: Bool = true) throws
        -> AppDatabase
    {
        let database = try AppDatabase.inMemory()
        try UserRepository(database: database).save(.fixture(email: email, active: active))
        return database
    }

    @Test("a reset clears a login lockout")
    func resetClearsLockout() throws {
        let database = try self.database(email: "locked@example.com")
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO login_attempt (email, failures, locked_until) VALUES (?, 5, ?)",
                arguments: ["locked@example.com", Date().addingTimeInterval(900)])
        }

        try AdminOperations.resetPassword(
            "a-new-password", forEmail: "locked@example.com", in: database, hasher: .testing)

        // Otherwise the reset hands back an account the owner still cannot log
        // into, which is the situation the command exists to end.
        let remaining = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM login_attempt")
        }
        #expect(remaining == 0)
    }

    @Test("a reset ends the sessions the old password was protecting")
    func resetEndsSessions() throws {
        let database = try self.database()
        let user = try #require(try UserRepository(database: database).find(email: "saqib@example.com"))
        let sessions = SessionRepository(database: database)
        try sessions.create(for: user.id, kind: .human, deviceId: "mac")

        try AdminOperations.resetPassword(
            "a-new-password", forEmail: user.email, in: database, hasher: .testing)

        #expect(try sessions.list(for: user.id).isEmpty)
    }

    /// A password on a deactivated account grants nothing, so setting one would
    /// leave an operator believing they had restored access.
    @Test("a deactivated account is refused")
    func deactivatedAccountRefused() throws {
        let database = try self.database(email: "gone@example.com", active: false)

        #expect(throws: AdminOperations.Failure.deactivated("gone@example.com")) {
            try AdminOperations.resetPassword(
                "a-new-password", forEmail: "gone@example.com", in: database, hasher: .testing)
        }
        #expect(AdminOperations.Failure.deactivated("gone@example.com").description.contains("Reactivate"))
    }

    @Test("an unknown email is refused")
    func unknownEmailRefused() throws {
        let database = try self.database()

        #expect(throws: AdminOperations.Failure.noSuchUser("ghost@example.com")) {
            try AdminOperations.resetPassword(
                "a-new-password", forEmail: "ghost@example.com", in: database, hasher: .testing)
        }
    }

    /// The API's rules apply here too: a password set on the host is not held to a
    /// lower standard than one set over HTTP.
    @Test("a weak password is refused, with the reason")
    func weakPasswordRefused() throws {
        let database = try self.database()

        let failure = #expect(throws: AdminOperations.Failure.self) {
            try AdminOperations.resetPassword(
                "short", forEmail: "saqib@example.com", in: database, hasher: .testing)
        }
        #expect(failure?.description.contains("at least") == true)
    }
}
