import Core
import Foundation
import Hummingbird

/// Assembles the HTTP surface.
///
/// `/health` sits outside the authenticated group deliberately: it is unversioned
/// and unauthenticated so a liveness probe keeps working across an API version
/// change and needs no credentials (ticket 06).
public enum IssuesRouter {

    public static let serverVersion = "0.1.0"

    public static func build(database: AppDatabase) -> Router<AppRequestContext> {
        let router = Router(context: AppRequestContext.self)

        router.get("/health") { _, _ in "ok" }

        let api = router.group("/api/v1")
        api.add(middleware: AuthenticationMiddleware(sessions: SessionRepository(database: database)))

        api.get("/meta") { _, _ in
            try EditedResponse(
                status: .ok,
                response: ServerMeta(
                    serverVersion: serverVersion,
                    apiVersions: ["v1"],
                    instanceName: try InstanceRepository(database: database).name()
                ))
        }

        ProjectRoutes(database: database).register(on: api)
        IssueRoutes(database: database).register(on: api)

        return router
    }
}
