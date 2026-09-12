import Core
import Foundation
import GRDB

/// Resolves ticket 06's `expand` relationships.
///
/// Batched on purpose: expansion exists because a 50-row list view is otherwise an
/// N+1, so resolving it one issue at a time would reintroduce the problem it was
/// added to solve. Four queries at most, whatever the page size.
struct IssueExpansion: Sendable {
    let database: AppDatabase

    func expand(_ issues: [Issue], with expansions: [Expansion]) throws -> [ExpandedIssue] {
        guard !expansions.isEmpty else {
            return issues.map { ExpandedIssue(issue: $0) }
        }
        let wanted = Set(expansions)

        // One query per relationship for the whole page, not per row.
        let users =
            wanted.contains(.assignee) || wanted.contains(.reporter)
            ? try usersByID(
                ids: issues.compactMap(\.assigneeId) + issues.map(\.reporterId))
            : [:]
        let projects =
            wanted.contains(.project)
            ? try projectsByID(ids: issues.map(\.projectId))
            : [:]
        let labels =
            wanted.contains(.labels)
            ? try labelsByIssue(ids: issues.map(\.id))
            : [:]

        return issues.map { issue in
            ExpandedIssue(
                issue: issue,
                // Requested-and-none is `[]`, which is a different answer from
                // not-requested, and a client rendering a label row needs both.
                labels: wanted.contains(.labels) ? (labels[issue.id] ?? []) : nil,
                assignee: wanted.contains(.assignee)
                    ? issue.assigneeId.flatMap { users[$0] } : nil,
                reporter: wanted.contains(.reporter) ? users[issue.reporterId] : nil,
                project: wanted.contains(.project) ? projects[issue.projectId] : nil)
        }
    }

    private func usersByID(ids: [User.ID]) throws -> [User.ID: User] {
        let unique = Set(ids)
        guard !unique.isEmpty else { return [:] }

        return try database.reader.read { db in
            let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM user WHERE id IN (\(placeholders))",
                arguments: StatementArguments(unique.map(\.rawValue.uuidString)))
            return try rows.reduce(into: [:]) { result, row in
                let user = try UserRepository.user(from: row)
                result[user.id] = user
            }
        }
    }

    private func projectsByID(ids: [Project.ID]) throws -> [Project.ID: Project] {
        let unique = Set(ids)
        guard !unique.isEmpty else { return [:] }

        return try database.reader.read { db in
            let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM project WHERE id IN (\(placeholders))",
                arguments: StatementArguments(unique.map(\.rawValue.uuidString)))
            return try rows.reduce(into: [:]) { result, row in
                let project = try ProjectRepository.project(from: row)
                result[project.id] = project
            }
        }
    }

    private func labelsByIssue(ids: [Issue.ID]) throws -> [Issue.ID: [Label]] {
        guard !ids.isEmpty else { return [:] }

        return try database.reader.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            // Joined rather than two queries and a merge in Swift; a tombstoned
            // label or membership is excluded, so a removed label does not reappear.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT il.issue_id AS issue_id, l.*
                    FROM issue_label il JOIN label l ON l.id = il.label_id
                    WHERE il.issue_id IN (\(placeholders))
                      AND il.deleted_at IS NULL AND l.deleted_at IS NULL
                    ORDER BY l.name COLLATE NOCASE
                    """,
                arguments: StatementArguments(ids.map(\.rawValue.uuidString)))

            return try rows.reduce(into: [:]) { result, row in
                guard let uuid = UUID(uuidString: row["issue_id"]) else { return }
                result[Issue.ID(uuid), default: []].append(try LabelRepository.label(from: row))
            }
        }
    }
}

extension AppRequestContext {
    /// Reads the `expand` parameter, refusing anything not whitelisted.
    func expansions(from query: some Collection<(key: Substring, value: Substring)>) throws
        -> [Expansion]
    {
        guard let raw = query.first(where: { $0.key == "expand" })?.value else { return [] }
        do {
            return try Expansion.parse(String(raw))
        } catch let error as ExpansionError {
            throw ProblemError.invalid([
                ValidationFailure(field: "expand", code: .invalid, message: error.description)
            ])
        }
    }
}
