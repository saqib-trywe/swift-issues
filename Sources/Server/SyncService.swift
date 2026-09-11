import Core
import Foundation
import GRDB

/// Applies queued offline operations.
///
/// One transaction **per operation**, not per batch. A single-transaction batch
/// would let one rejected operation roll back the rest, which is exactly the
/// head-of-line blocking ADR 0004 exists to prevent — and that failure is
/// invisible: all sync freezes behind one bad record with nothing reported.
struct SyncService: Sendable {
    let database: AppDatabase
    let identity: Authenticated

    private var issues: IssueRepository { IssueRepository(database: database) }
    private var comments: CommentRepository { CommentRepository(database: database) }
    private var labels: LabelRepository { LabelRepository(database: database) }

    func apply(_ batch: SyncPush) throws -> SyncPushResponse {
        var results: [SyncResult] = []
        for operation in batch.operations {
            results.append(outcome(for: operation))
        }
        return SyncPushResponse(
            watermark: try currentWatermark(), results: results)
    }

    /// Never throws: every failure becomes a per-operation outcome, because a
    /// throw here would fail the batch and strand the operations after it.
    private func outcome(for operation: SyncOperation) -> SyncResult {
        // Replay safety: an operation already applied returns its original answer
        // rather than being applied a second time.
        if let recorded = (try? recordedOutcome(operation.opId)) ?? nil {
            return SyncResult(
                opId: operation.opId, outcome: recorded, serverTimestamp: nil, problem: nil,
                current: nil)
        }

        do {
            let result = try perform(operation)
            try? record(operation.opId, outcome: result.outcome)
            return result
        } catch let problem as ProblemError {
            try? record(operation.opId, outcome: .rejected)
            return SyncResult(
                opId: operation.opId, outcome: .rejected, serverTimestamp: nil,
                problem: problem.problem, current: nil)
        } catch {
            // An unexpected failure is still a rejection rather than a batch
            // failure: the operations after it are unrelated and must proceed.
            try? record(operation.opId, outcome: .rejected)
            return SyncResult(
                opId: operation.opId, outcome: .rejected, serverTimestamp: nil,
                problem: ProblemError.invalid([
                    ValidationFailure(
                        field: "operation", code: .required,
                        message: "This operation could not be applied.")
                ]).problem,
                current: nil)
        }
    }

    private func perform(_ operation: SyncOperation) throws -> SyncResult {
        let now = Date()

        switch operation {
        case .putIssue(let opId, let id, _, let body):
            if let existing = try issues.find(id) {
                return superseded(opId, existing) ?? applied(opId, now)
            }
            let failures = Validation.issue(title: body.title, description: body.description)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }
            let draft = Issue(
                id: id, key: nil, projectId: body.projectId, title: body.title,
                description: body.description, status: body.status, priority: body.priority,
                reporterId: identity.userId, assigneeId: body.assigneeId, dueDate: body.dueDate,
                via: identity.kind == .human ? .human : .agent, createdAt: now, updatedAt: now)
            _ = try issues.create(draft)
            return applied(opId, now)

        case .patchIssue(let opId, let id, _, let body):
            guard let existing = try issues.find(id) else {
                throw ProblemError.notFound(detail: "No such issue.")
            }
            if let lost = superseded(opId, existing) { return lost }
            if case .set(let title) = body.title {
                let failures = Validation.title(title)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
            }
            _ = try issues.apply(body, to: id, at: now)
            return applied(opId, now)

        case .deleteIssue(let opId, let id, _):
            guard let existing = try issues.find(id) else {
                throw ProblemError.notFound(detail: "No such issue.")
            }
            if let lost = superseded(opId, existing) { return lost }
            try issues.delete(id, at: now)
            return applied(opId, now)

        case .putComment(let opId, let id, _, let body):
            if let existing = try comments.find(id) {
                return supersededComment(opId, existing) ?? applied(opId, now)
            }
            let failures = Validation.comment(body: body.body)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }
            // A reference the server has not seen is rejected (ticket 08): causal
            // order is the client's responsibility.
            guard let issue = try issues.find(body.issueId), issue.deletedAt == nil else {
                throw ProblemError.notFound(detail: "No such issue.")
            }
            try comments.save(
                Comment(
                    id: id, issueId: body.issueId, authorId: identity.userId, body: body.body,
                    via: identity.kind == .human ? .human : .agent, createdAt: now,
                    updatedAt: now))
            return applied(opId, now)

        case .patchComment(let opId, let id, _, let body):
            guard var existing = try comments.find(id) else {
                throw ProblemError.notFound(detail: "No such comment.")
            }
            if let lost = supersededComment(opId, existing) { return lost }
            guard existing.authorId == identity.userId else {
                throw ProblemError.forbidden(detail: "Only the author can edit a comment.")
            }
            if case .set(let text) = body.body {
                let failures = Validation.comment(body: text)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
                existing.body = text
                existing.updatedAt = now
            }
            try comments.save(existing)
            return applied(opId, now)

        case .deleteComment(let opId, let id, _):
            guard let existing = try comments.find(id) else {
                throw ProblemError.notFound(detail: "No such comment.")
            }
            if let lost = supersededComment(opId, existing) { return lost }
            guard existing.authorId == identity.userId || identity.role == .admin else {
                throw ProblemError.forbidden(
                    detail: "Only the author or an Admin can delete a comment.")
            }
            try comments.delete(id, at: now)
            return applied(opId, now)

        case .putLabel(let opId, let id, _, let body):
            let failures = Validation.labelName(body.name)
            guard failures.isEmpty else { throw ProblemError.invalid(failures) }
            guard let existing = try labels.find(id) else {
                throw ProblemError.notFound(
                    detail: "A label must be created through its project first.")
            }
            _ = try labels.save(
                Label(
                    id: id, projectId: existing.projectId, name: body.name, color: body.color,
                    createdAt: existing.createdAt, updatedAt: now))
            return applied(opId, now)

        case .patchLabel(let opId, let id, _, let body):
            guard var existing = try labels.find(id) else {
                throw ProblemError.notFound(detail: "No such label.")
            }
            if case .set(let name) = body.name {
                let failures = Validation.labelName(name)
                guard failures.isEmpty else { throw ProblemError.invalid(failures) }
                existing.name = name
            }
            if case .set(let color) = body.color { existing.color = color }
            existing.updatedAt = now
            _ = try labels.save(existing)
            return applied(opId, now)

        case .deleteLabel(let opId, let id, _):
            guard try labels.find(id) != nil else {
                throw ProblemError.notFound(detail: "No such label.")
            }
            try labels.delete(id, at: now)
            return applied(opId, now)

        case .addLabel(let opId, _, _, let issueId, let labelId):
            guard let issue = try issues.find(issueId), issue.deletedAt == nil else {
                throw ProblemError.notFound(detail: "No such issue.")
            }
            guard let label = try labels.find(labelId), label.deletedAt == nil,
                label.projectId == issue.projectId
            else {
                throw ProblemError.invalid([
                    ValidationFailure(
                        field: "labelId", code: .required,
                        message: "That label does not belong to this issue's project.")
                ])
            }
            try labels.attach(labelId: labelId, to: issueId, at: now)
            return applied(opId, now)

        case .removeLabel(let opId, let id, _):
            // The link is addressed by its own id, so the pair is looked up first.
            guard let pair = try linkPair(id) else {
                throw ProblemError.notFound(detail: "No such label link.")
            }
            try labels.detach(labelId: pair.labelId, from: pair.issueId, at: now)
            return applied(opId, now)
        }
    }

    // MARK: Outcomes

    private func applied(_ opId: UUID, _ now: Date) -> SyncResult {
        SyncResult(
            opId: opId, outcome: .applied, serverTimestamp: now, problem: nil, current: nil)
    }

    /// Deletion is terminal: a tombstone is not a value last-write-wins can
    /// overwrite, so a write against one loses and the winner is handed back.
    private func superseded(_ opId: UUID, _ issue: Issue) -> SyncResult? {
        guard issue.deletedAt != nil else { return nil }
        return SyncResult(
            opId: opId, outcome: .superseded, serverTimestamp: nil, problem: nil,
            current: .issue(issue))
    }

    private func supersededComment(_ opId: UUID, _ comment: Comment) -> SyncResult? {
        guard comment.deletedAt != nil else { return nil }
        return SyncResult(
            opId: opId, outcome: .superseded, serverTimestamp: nil, problem: nil,
            current: .comment(comment))
    }

    // MARK: Ledger

    private func recordedOutcome(_ opId: UUID) throws -> SyncOutcome? {
        try database.reader.read { db in
            guard
                let raw = try String.fetchOne(
                    db, sql: "SELECT outcome FROM applied_operation WHERE op_id = ?",
                    arguments: [opId.uuidString])
            else { return nil }
            return SyncOutcome(rawValue: raw)
        }
    }

    private func record(_ opId: UUID, outcome: SyncOutcome) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO applied_operation (op_id, outcome, applied_at) VALUES (?, ?, ?)
                    ON CONFLICT (op_id) DO NOTHING
                    """,
                arguments: [opId.uuidString, outcome.rawValue, Date()])
        }
    }

    private func linkPair(_ id: ID<IssueLabel>) throws -> (issueId: Issue.ID, labelId: Label.ID)? {
        try database.reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT issue_id, label_id FROM issue_label WHERE id = ?",
                    arguments: [id.rawValue.uuidString]),
                let issueUUID = UUID(uuidString: row["issue_id"]),
                let labelUUID = UUID(uuidString: row["label_id"])
            else { return nil }
            return (Issue.ID(issueUUID), Label.ID(labelUUID))
        }
    }

    func currentWatermark() throws -> Watermark {
        let epoch = try InstanceRepository(database: database).epoch()
        let sequence: Int = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM change_cursor") ?? 0
        }
        return Watermark(epoch: epoch, sequence: sequence)
            ?? Watermark(epoch: "unknown", sequence: 0)!
    }
}
