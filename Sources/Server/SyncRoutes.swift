import Core
import Foundation
import Hummingbird

/// The sync pair.
///
/// A separate contract from the REST surface (ADR 0005) because the shapes are
/// irreconcilable: this side needs batched writes with per-operation outcomes and a
/// delta stream carrying tombstones.
struct SyncRoutes: Sendable {
    let database: AppDatabase

    func register(on group: RouterGroup<AppRequestContext>) {
        // Always 200 with per-operation results. A top-level 4xx is reserved for a
        // malformed batch or an auth failure — per ADR 0006 a 401 preserves the
        // client's pending queue rather than quarantining valid writes.
        group.post("/sync/push") { request, context in
            try context.requireCapability(.write)
            let batch = try await request.decode(as: SyncPush.self, context: context)
            let service = SyncService(database: database, identity: context.identity)
            return try EditedResponse(status: .ok, response: try service.apply(batch))
        }
    }
}

extension SyncPushResponse: ResponseEncodable {}
