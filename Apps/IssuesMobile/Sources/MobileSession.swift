import AppCore
import ClientStore
import Core
import Credentials
import Foundation
import Observation

/// The iOS app's session.
///
/// Deliberately narrower than the Mac's: ticket 10 keeps token and session
/// administration on macOS only, because there is no web UI and the Mac is where
/// an operator sits. This one reads, writes and syncs.
@MainActor
@Observable
final class MobileSession {
    private(set) var list: IssueListModel?
    private(set) var projects: [Project] = []
    private(set) var startupFailure: String?

    var selectedProject: Project.ID? {
        didSet { if selectedProject != oldValue { list?.projectId = selectedProject } }
    }

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverURL") }
    }

    private var database: ReplicaDatabase?
    private var engine: SyncEngine?
    private let credentials: any CredentialStore = KeychainCredentialStore()

    var token: String? {
        get { try? credentials.token(forServer: serverURL) }
        set {
            guard !serverURL.isEmpty else { return }
            if let newValue, !newValue.isEmpty {
                try? credentials.store(newValue, forServer: serverURL)
            } else {
                try? credentials.remove(forServer: serverURL)
            }
        }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !(token ?? "").isEmpty }

    var writer: IssueWriter? { database.map(IssueWriter.init(database:)) }

    func start() async {
        guard list == nil else { return }
        do {
            let database = try ReplicaDatabase.open(at: try Self.databaseURL())
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
        await sync()
    }

    func sync() async {
        guard isConfigured, let database, let list else { return }
        guard let url = URL(string: serverURL), let token else { return }

        let engine = self.engine ?? SyncEngine(
            database: database,
            client: APIClient(transport: URLSessionTransport(baseURL: url), token: { token }),
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
            if case .unauthenticated = error {
                list.setAuthentication(.needsReauthentication)
                list.setProgress(.idle)
            } else {
                list.setProgress(.failed("The server could not be reached."))
            }
        } catch {
            list.setProgress(.failed(String(describing: error)))
        }
    }

    func afterLocalWrite() {
        list?.reload()
        Task { await sync() }
    }

    func comments(for id: Issue.ID) -> [Core.Comment] {
        (try? database?.comments(forIssue: id)) ?? []
    }

    func issue(_ id: Issue.ID) -> Overlaid<Issue>? {
        list?.issues.first { $0.record.id == id }
    }

    private func reloadProjects() {
        projects = (try? database?.projects()) ?? []
        if selectedProject == nil { selectedProject = projects.first?.id }
    }

    /// iOS gives every app its own container, so this is simply Application
    /// Support — there is no shared home to be careful about.
    static func databaseURL() throws -> URL {
        let directory = URL.applicationSupportDirectory.appending(path: "Issues")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "replica.sqlite")
    }

    static let deviceId: String = {
        let key = "deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUIDv7.generate().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()
}
