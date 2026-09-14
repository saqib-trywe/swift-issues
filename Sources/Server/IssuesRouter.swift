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

    public static func build(
        database: AppDatabase,
        rateLimiter: AgentRateLimiter = AgentRateLimiter()
    ) -> Router<AppRequestContext> {
        let router = Router(context: AppRequestContext.self)

        // Outermost, so it also catches what the router itself raises — an unmatched
        // path, or a body that will not decode — and not only what the handlers do.
        router.add(middleware: ProblemMiddleware())

        router.get("/health") { _, _ in "ok" }

        // Login sits outside the authenticated group: it is how a token is
        // obtained in the first place.
        // Cheap hashing parameters in tests would be unsafe in production, so the
        // production hasher is the default and tests inject their own.
        let auth = LoginRoutes(database: database, hasher: PasswordHasher.production)
        auth.register(on: router.group("/api/v1"))
        auth.registerBootstrap(on: router.group("/api/v1"))

        let api = router.group("/api/v1")
        api.add(middleware: AuthenticationMiddleware(sessions: SessionRepository(database: database)))
        // After authentication, because the limit is per token and depends on the
        // token's kind — neither is known before then (ticket 12).
        api.add(middleware: AgentRateLimitMiddleware(limiter: rateLimiter))

        api.get("/meta") { _, _ in
            try EditedResponse(
                status: .ok,
                response: ServerMeta(
                    serverVersion: serverVersion,
                    apiVersions: ["v1"],
                    instanceName: try InstanceRepository(database: database).name()
                ))
        }

        UserRoutes(database: database, hasher: PasswordHasher.production).register(on: api)
        TokenRoutes(database: database).register(on: api)
        ProjectRoutes(database: database).register(on: api)
        IssueRoutes(database: database).register(on: api)
        CommentRoutes(database: database).register(on: api)
        LabelRoutes(database: database).register(on: api)
        SyncRoutes(database: database).register(on: api)

        return router
    }
}
