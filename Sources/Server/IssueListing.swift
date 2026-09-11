import Core
import Foundation
import GRDB

/// A page position.
///
/// Opaque to callers by contract (ticket 06) and keyed on (sort value, id) rather
/// than an offset: rows are created and deleted while a client pages, and offset
/// paging silently skips and duplicates. The id breaks ties so the order is total.
struct ListCursor: Codable {
    let value: String
    let id: String

    func encoded() -> String {
        (try? JSONCoders.encoder.encode(self))
            .map { $0.base64EncodedString() } ?? ""
    }

    static func decode(_ raw: String) -> ListCursor? {
        guard let data = Data(base64Encoded: raw) else { return nil }
        return try? JSONCoders.decoder.decode(ListCursor.self, from: data)
    }
}

extension IssueRepository {

    /// Lists Issues matching a filter.
    ///
    /// `resolvingMeAs` is supplied by the route rather than read here: the
    /// repository has no notion of who is calling, and `assignee=me` is an
    /// ergonomic token (ticket 06) rather than a stored value.
    public func list(
        filter: IssueFilter,
        sort: IssueSort?,
        page: Pagination,
        resolvingMeAs caller: User.ID
    ) throws -> Paginated<Issue> {
        var conditions: [String] = ["i.deleted_at IS NULL"]
        var arguments: [(any DatabaseValueConvertible)?] = []

        if let projectKey = filter.projectKey {
            conditions.append("p.key = ?")
            arguments.append(projectKey.wireValue)
        }

        // Values within one field are OR-ed; each field adds its own AND.
        if !filter.statuses.isEmpty {
            conditions.append(inClause("i.status", filter.statuses.map(\.wireValue), &arguments))
        }
        if !filter.priorities.isEmpty {
            conditions.append(
                inClause("i.priority", filter.priorities.map(\.wireValue), &arguments))
        }

        switch filter.assignee {
        case .me:
            conditions.append("i.assignee_id = ?")
            arguments.append(caller.rawValue.uuidString)
        case .unassigned:
            conditions.append("i.assignee_id IS NULL")
        case .user(let id):
            conditions.append("i.assignee_id = ?")
            arguments.append(id.rawValue.uuidString)
        case nil:
            break
        }

        if !filter.labels.isEmpty {
            // Tombstoned links must not match: membership is a record that is
            // removed by tombstoning, not by deletion.
            conditions.append(
                """
                EXISTS (
                    SELECT 1 FROM issue_label il
                    JOIN label l ON l.id = il.label_id
                    WHERE il.issue_id = i.id AND il.deleted_at IS NULL
                      AND \(inClause("l.name", filter.labels, &arguments))
                )
                """)
        }

        if let updatedSince = filter.updatedSince {
            conditions.append("i.updated_at >= ?")
            arguments.append(updatedSince)
        }

        if let query = filter.query, !query.isEmpty {
            // Substring over title and description in v1; the map records that real
            // search depth is unspecified.
            conditions.append("(i.title LIKE ? OR i.description LIKE ?)")
            arguments.append("%\(query)%")
            arguments.append("%\(query)%")
        }

        let order = sort ?? .updatedAt(descending: true)
        let (column, descending) = Self.ordering(order)

        if let cursor = page.cursor.flatMap(ListCursor.decode) {
            // Keyset comparison rather than an offset: a row inserted ahead of the
            // client's position cannot shift the remainder.
            let comparison = descending ? "<" : ">"
            conditions.append(
                "(\(column) \(comparison) ? OR (\(column) = ? AND i.id \(comparison) ?))")
            arguments.append(cursor.value)
            arguments.append(cursor.value)
            arguments.append(cursor.id)
        }

        let direction = descending ? "DESC" : "ASC"
        // One extra row, to learn whether another page exists without a count.
        let sql = """
            SELECT i.*, p.key AS project_key FROM issue i
            JOIN project p ON p.id = i.project_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(column) \(direction), i.id \(direction)
            LIMIT \(page.limit + 1)
            """

        return try database.reader.read { db in
            var rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let hasMore = rows.count > page.limit
            if hasMore { rows.removeLast() }

            let items = try rows.map(Self.issue(from:))
            let nextCursor =
                hasMore
                ? rows.last.map {
                    ListCursor(
                        value: Self.cursorValue($0, column: column), id: $0["id"]
                    ).encoded()
                }
                : nil
            return Paginated(items: items, nextCursor: nextCursor)
        }
    }

    private func inClause(
        _ column: String, _ values: [String], _ arguments: inout [(any DatabaseValueConvertible)?]
    ) -> String {
        arguments.append(contentsOf: values.map { $0 })
        return "\(column) IN (\(values.map { _ in "?" }.joined(separator: ", ")))"
    }

    static func ordering(_ sort: IssueSort) -> (column: String, descending: Bool) {
        switch sort {
        case .updatedAt(let descending): ("i.updated_at", descending)
        case .createdAt(let descending): ("i.created_at", descending)
        case .dueDate(let descending): ("i.due_date", descending)
        case .priority(let descending): ("i.priority", descending)
        }
    }

    /// Cursors carry the sort value as text, which is how SQLite compares the
    /// stored form anyway.
    static func cursorValue(_ row: Row, column: String) -> String {
        let name = String(column.dropFirst("i.".count))
        return (row[name] as DatabaseValue?).map { value in
            switch value.storage {
            case .string(let text): text
            case .int64(let number): String(number)
            case .double(let number): String(number)
            default: ""
            }
        } ?? ""
    }
}
