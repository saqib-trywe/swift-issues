import Core
import Foundation
import Hummingbird

/// What an authenticated caller is allowed to do.
///
/// Deliberately coarse. ADR 0007 rejected a general scope system: two fixed
/// profiles are not configurable, have no per-field grants and no custom roles.
public enum Capability: Sendable {
    /// Create or modify Issues, Comments and Labels.
    case write
    /// Hard delete. Agents never get this — an agent looping on a misparsed
    /// instruction is exactly the actor not to hand an irreversible tombstone to.
    case destructive
    /// User management and Instance administration.
    case administer
}

/// The request context carried through the router.
public struct AppRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// Set by `AuthenticationMiddleware`; absent before it runs.
    public var authenticated: Authenticated?

    public init(source: Source) {
        self.coreContext = .init(source: source)
        self.authenticated = nil
    }

    /// The shared coders, so handlers cannot drift from the wire conventions in
    /// ticket 06 — camelCase keys, RFC 3339 instants, calendar dates for dueDate.
    public var requestDecoder: JSONDecoder { JSONCoders.decoder }
    public var responseEncoder: JSONEncoder { JSONCoders.encoder }
}

extension AppRequestContext {

    /// The caller. Only reachable behind `AuthenticationMiddleware`, which rejects
    /// the request before a handler runs if there is nobody.
    public var identity: Authenticated {
        guard let authenticated else {
            preconditionFailure(
                "identity read outside AuthenticationMiddleware — the route is misconfigured")
        }
        return authenticated
    }

    /// Role check, for permissions a route can state declaratively.
    ///
    /// An Agent never satisfies a Role requirement regardless of its owner's Role:
    /// an Admin's agent is not an admin (ADR 0007).
    public func require(_ role: Role) throws {
        guard identity.kind == .human, identity.role == role else {
            throw ProblemError.forbidden(
                detail: "This action requires the \(role.wireValue) role.")
        }
    }

    /// Capability check, for the fixed agent profile.
    public func requireCapability(_ capability: Capability) throws {
        guard identity.capabilities.contains(capability) else {
            throw ProblemError.forbidden(
                detail: "This token is not permitted to perform that action.")
        }
    }
}

extension Authenticated {
    /// An Agent's authority is fixed and narrower than its owner's, whatever that
    /// owner's Role. Widening this is a version change, not a configuration.
    var capabilities: Set<Capability> {
        switch kind {
        case .human:
            role == .admin ? [.write, .destructive, .administer] : [.write, .destructive]
        case .agent:
            [.write]
        case .agentReadonly:
            []
        // A kind this build does not recognise gets nothing. Defaulting to the
        // human set would widen an unknown token's authority to the maximum,
        // which is the wrong direction to be wrong in.
        case .unknown:
            []
        }
    }
}
