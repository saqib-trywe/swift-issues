import Core
import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import ServerTestSupport
import TestSupport

@testable import ClientStore
@testable import Server

/// One device: its own replica, its own queue, its own engine.
struct Device: Sendable {
    let database: ReplicaDatabase
    let engine: SyncEngine
    let id: String
}

/// A server plus however many devices a test needs.
struct SyncWorld: Sendable {
    let database: AppDatabase
    let transport: RouterTransport
    let owner: Core.User
    let project: Project
    let token: String

    /// A fresh device, with an empty replica and no watermark.
    func device(_ name: String = "device") throws -> Device {
        let replica = try ReplicaDatabase.inMemory()
        let token = self.token
        return Device(
            database: replica,
            engine: SyncEngine(
                database: replica,
                client: APIClient(transport: transport, token: { token }),
                deviceId: name),
            id: name)
    }

    /// What the server currently holds for an issue.
    func serverIssue(_ id: Core.Issue.ID) throws -> Core.Issue? {
        try IssueRepository(database: database).find(id)
    }
}

func withSync(_ body: @Sendable @escaping (SyncWorld) async throws -> Void) async throws {
    let database = try AppDatabase.inMemory()

    let owner = Core.User.fixture(email: "user@example.com", displayName: "Example User", role: .admin)
    try UserRepository(database: database).save(owner)
    let project = Project.fixture()
    try ProjectRepository(database: database).save(project)

    let session = try SessionRepository(database: database).create(
        for: owner.id, kind: .human, deviceId: nil, label: "sync tests")

    let application = Application(router: IssuesRouter.build(database: database))
    try await application.test(.router) { client in
        try await body(
            SyncWorld(
                database: database,
                transport: RouterTransport(client: client),
                owner: owner,
                project: project,
                token: session.raw))
    }
}
