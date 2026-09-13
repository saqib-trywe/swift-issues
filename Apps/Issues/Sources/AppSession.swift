import AppCore
import ClientStore
import Core
import Credentials
import Foundation
import Observation
import SwiftUI

/// Everything the app needs that outlives a view.
///
/// Holds the replica, the sync engine and the list model. Deliberately the only
/// place that knows how they are wired together — the views take a model and know
/// nothing about databases or tokens.
@MainActor
@Observable
final class AppSession {
    private(set) var list: IssueListModel?
    private(set) var projects: [Project] = []
    private(set) var startupFailure: String?

    var selectedProject: Project.ID? {
        didSet { list?.projectId = selectedProject }
    }
    var selectedIssue: Issue.ID?

    /// Where the server is. Stored in preferences; the token is not.
    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverURL")
            restart()
        }
    }

    private var database: ReplicaDatabase?
    private var engine: SyncEngine?
    private let credentials: any CredentialStore = KeychainCredentialStore()

    /// The token, read from the Keychain rather than preferences — the same store
    /// the CLI uses, keyed by server so a test instance cannot clobber a real one.
    var token: String? {
        get { try? credentials.token(forServer: serverURL) }
        set {
            guard !serverURL.isEmpty else { return }
            if let newValue, !newValue.isEmpty {
                try? credentials.store(newValue, forServer: serverURL)
            } else {
                try? credentials.remove(forServer: serverURL)
            }
            restart()
        }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !(token ?? "").isEmpty }

    /// Queues writes into the replica. Nil until the database is open.
    ///
    /// Writes never go straight to the network: they land in the queue, show
    /// through the overlay at once, and the engine sends them when it can. That is
    /// what makes the app work on a plane.
    var writer: IssueWriter? {
        database.map(IssueWriter.init(database:))
    }

    /// Refreshes after a local write, then tries to send it.
    ///
    /// The write is already visible either way — the sync is opportunistic, not
    /// something the user waits on.
    func afterLocalWrite() {
        list?.reload()
        Task { await sync() }
    }

    /// An issue's comment thread from the replica.
    func comments(for id: Issue.ID) -> [Core.Comment] {
        (try? database?.comments(forIssue: id)) ?? []
    }

    /// A token model bound to the current connection, or nil when there is none.
    func makeTokenModel() -> TokenListModel? {
        guard let url = URL(string: serverURL), let token, !token.isEmpty else { return nil }
        return TokenListModel(
            client: APIClient(transport: URLSessionTransport(baseURL: url), token: { token }))
    }

    /// What signing out would cost right now.
    var logoutPlan: LogoutPlan {
        LogoutPlan(status: list?.status ?? SyncStatus())
    }

    /// Signs out and removes the local copy.
    ///
    /// Ticket 07 is explicit that logout clears the replica; anything unsent goes
    /// with it, which is why the confirmation names the count first.
    func signOut() {
        list?.stopObserving()
        list = nil
        engine = nil
        try? credentials.remove(forServer: serverURL)
        if let url = try? Self.databaseURL() {
            try? FileManager.default.removeItem(at: url)
            // The write-ahead log and shared memory are separate files; leaving them
            // behind would resurrect part of the replica on next open.
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                        .appending(path: url.lastPathComponent + suffix))
            }
        }
        projects = []
        selectedProject = nil
        selectedIssue = nil
        Task { await start() }
    }

    func start() async {
        guard list == nil else { return }
        open()
        await sync()
    }

    /// Opens the replica and starts observing it.
    ///
    /// The database is opened even when there is no server configured, so the app
    /// is usable offline against whatever was synced last — which is the whole
    /// point of holding a replica.
    private func open() {
        do {
            let url = try Self.databaseURL()
            let database = try ReplicaDatabase.open(at: url)
            self.database = database

            let model = IssueListModel(database: database)
            model.startObserving()
            model.reload()
            list = model

            reloadProjects()
            startupFailure = nil
        } catch {
            startupFailure = String(describing: error)
        }
    }

    private func restart() {
        list?.stopObserving()
        list = nil
        engine = nil
        Task { await start() }
    }

    /// Push, then pull. Progress is written onto the model so every sync surface
    /// sees it.
    func sync() async {
        guard isConfigured, let database, let list else { return }
        guard let url = URL(string: serverURL), let token else { return }

        let engine = self.engine ?? SyncEngine(
            database: database,
            client: APIClient(
                transport: URLSessionTransport(baseURL: url), token: { token }),
            deviceId: Self.deviceId)
        self.engine = engine

        list.setProgress(.syncing)
        do {
            let result = try await engine.sync()
            list.setProgress(result.pull.resynced ? .rebuilding : .idle)
            list.setAuthentication(.valid)
            reloadProjects()
            list.reload()
        } catch let error as APIError {
            // A rejected token is not a rejected write, and the remedy is signing in
            // rather than repairing anything (ticket 07).
            if case .unauthenticated = error {
                list.setAuthentication(.needsReauthentication)
                list.setProgress(.idle)
            } else {
                list.setProgress(.failed(IssuesApp.describe(error)))
            }
        } catch {
            list.setProgress(.failed(String(describing: error)))
        }
    }

    private func reloadProjects() {
        projects = (try? database?.projects()) ?? []
        if selectedProject == nil { selectedProject = projects.first?.id }
    }

    /// Everything under the user's own Application Support, honouring `$HOME` for
    /// the same reason the server does: otherwise a sandboxed run writes into the
    /// real one.
    static func databaseURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let support: URL =
            if let home = environment["HOME"], !home.isEmpty {
                URL(fileURLWithPath: home)
                    .appending(path: "Library").appending(path: "Application Support")
            } else {
                .applicationSupportDirectory
            }

        let directory = support.appending(path: "Issues")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory.appending(path: "replica.sqlite")
    }

    /// Stable per install, so the server can tell this device's writes from
    /// another's.
    static let deviceId: String = {
        let key = "deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUIDv7.generate().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()
}

extension IssuesApp {
    /// Server failures read as sentences rather than as enum cases.
    static func describe(_ error: APIError) -> String {
        switch error {
        case .unauthenticated: "Your session has expired."
        case .forbidden: "You do not have permission to do that."
        case .notFound: "The server could not find that."
        case .rateLimited: "Too many attempts — try again shortly."
        case .server(let status, _): "The server failed (HTTP \(status))."
        default: "The server could not be reached."
        }
    }
}
