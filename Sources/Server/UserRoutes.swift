import Core
import Foundation
import Hummingbird

/// Routes for the User resource.
///
/// There is no delete: a User is referenced as reporter, assignee and comment
/// author permanently, so removal would orphan history. Deactivation is a patch.
struct UserRoutes: Sendable {
    let database: AppDatabase
    /// Production parameters by default; tests inject cheap ones.
    var hasher: PasswordHasher = .production

    var repository: UserRepository { UserRepository(database: database) }

    func register(on group: RouterGroup<AppRequestContext>) {
        group.get("/users") { _, context in
            _ = context.identity
            return try EditedResponse(
                status: .ok, response: Paginated(items: try repository.all(), nextCursor: nil))
        }

        // Registered before `/users/:id` and matched as a literal. `UserRoutesTests`
        // asserts it is not shadowed: the two sit at the same path depth, and the
        // wrong precedence would 404 `me` for everybody.
        group.get("/users/me") { _, context in
            guard let user = try repository.find(context.identity.userId) else {
                // The session outlived its user, which the reaper should prevent.
                throw ProblemError.notFound(detail: "No such user.")
            }
            return try EditedResponse(status: .ok, response: user)
        }

        group.get("/users/:id") { _, context in
            guard let user = try repository.find(try context.userID()) else {
                throw ProblemError.notFound(detail: "No such user.")
            }
            return try EditedResponse(status: .ok, response: user)
        }

        group.put("/users/:id") { request, context in
            try context.require(.admin)
            let id = try context.userID()
            let body = try await request.decode(as: UserCreate.self, context: context)

            let failures = Validation.email(body.email) + Validation.displayName(body.displayName)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }

            // Create-only, like every other PUT here: the retry an offline client
            // makes when it never saw the response must not create a second account.
            if let existing = try repository.find(id) {
                guard existing.email.lowercased() == body.email.lowercased(),
                    existing.displayName == body.displayName, existing.role == body.role
                else {
                    throw ProblemError.conflict(
                        detail: "That id already exists with different content.")
                }
                return try EditedResponse(status: .ok, response: existing)
            }

            if try repository.find(email: body.email) != nil {
                throw ProblemError.conflict(detail: "That email address is already in use.")
            }

            let now = Date()
            let user = User(
                id: id, email: body.email, displayName: body.displayName, role: body.role,
                active: true, createdAt: now, updatedAt: now)
            try repository.save(user)
            return try EditedResponse(status: .created, response: user)
        }

        group.put("/users/:id/password") { request, context in
            // An agent may never set a password — not even its own owner's. That is
            // account control rather than tracker work, and ADR 0007 keeps an agent
            // narrower than its owner. Checked as a kind rather than through
            // `.administer`, which would also lock out a Member changing their own.
            guard context.identity.kind == .human else {
                throw ProblemError.forbidden(
                    detail: "An agent token may not set a password.")
            }
            let id = try context.userID()
            guard try repository.find(id) != nil else {
                throw ProblemError.notFound(detail: "No such user.")
            }
            let body = try await request.decode(as: PasswordChange.self, context: context)

            let failures = Validation.password(body.password)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }

            let caller = context.identity
            let isAdmin = caller.kind == .human && caller.role == .admin

            if caller.userId == id {
                // Your own password always needs the current one, Admin or not: a
                // hijacked session would otherwise be enough to lock the real owner
                // out of their own account permanently.
                guard let current = body.currentPassword,
                    let stored = try repository.credentials(forId: id),
                    try PasswordHasher.verify(current, against: stored)
                else {
                    throw ProblemError.forbidden(detail: "The current password is not correct.")
                }
            } else {
                guard isAdmin else {
                    throw ProblemError.forbidden(detail: "Only an Admin may set another user's password.")
                }
            }

            try repository.setPassword(try hasher.hash(body.password), for: id)
            // A changed password must end the sessions it was protecting, or
            // changing it does nothing about whoever you changed it because of.
            try SessionRepository(database: database).revokeAll(for: id)

            return HTTPResponse.Status.noContent
        }

        group.patch("/users/:id") { request, context in
            let id = try context.userID()
            guard var user = try repository.find(id) else {
                throw ProblemError.notFound(detail: "No such user.")
            }
            let patch = try await request.decode(as: UserPatch.self, context: context)

            let caller = context.identity
            let isAdmin = caller.kind == .human && caller.role == .admin
            let isSelf = caller.userId == id

            // Renaming yourself is ordinary; everything else about an account is
            // instance administration.
            if case .set(let name) = patch.displayName {
                guard isAdmin || isSelf else {
                    throw ProblemError.forbidden(detail: "You may only change your own display name.")
                }
                let failures = Validation.displayName(name)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
                user.displayName = name
            }

            // Self-promotion would make the Admin role decorative, so role and
            // activation are Admin-only even on your own account.
            if case .set(let role) = patch.role {
                guard isAdmin else {
                    throw ProblemError.forbidden(detail: "Only an Admin may change a role.")
                }
                user.role = role
            }

            var deactivated = false
            if case .set(let active) = patch.active {
                guard isAdmin else {
                    throw ProblemError.forbidden(detail: "Only an Admin may deactivate a user.")
                }
                deactivated = user.active && !active
                user.active = active
            }

            user.updatedAt = Date()
            try repository.save(user)

            // After the write, so a failure to save cannot leave someone logged out
            // of an account that is still active.
            if deactivated {
                try SessionRepository(database: database).revokeAll(for: id)
            }

            return try EditedResponse(status: .ok, response: user)
        }
    }
}

extension AppRequestContext {
    /// Reads and validates the `:id` path parameter.
    func userID() throws -> User.ID {
        guard let raw = parameters.get("id"), let uuid = UUID(uuidString: raw) else {
            throw ProblemError.notFound(detail: "No such user.")
        }
        return User.ID(uuid)
    }
}
