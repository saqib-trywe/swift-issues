import Foundation

/// A single rule violation on a single field.
///
/// The Swift side of ticket 06's `errors: [{field, code, message}]`. The `code`
/// is stable and machine-readable so five surfaces can react without
/// string-matching English prose; `message` is for humans and may change.
public struct ValidationFailure: Hashable, Sendable, Codable {
    public let field: String
    public let code: ValidationCode
    public let message: String

    public init(field: String, code: ValidationCode, message: String) {
        self.field = field
        self.code = code
        self.message = message
    }
}

/// Stable failure codes. Generic rather than per-field — the field is carried
/// separately — so adding a field does not add a code.
public enum ValidationCode: String, Hashable, Sendable, Codable {
    case required
    case tooLong
    case tooLarge
}

/// Pure, structural validation of values on their way *in*.
///
/// Deliberately not applied when decoding a server response: rejecting a value a
/// newer server considers valid would break every existing client, the same
/// failure the lenient wire enums exist to prevent. Contextual rules — that an
/// assignee exists and is active, that a Label belongs to the Issue's Project —
/// need the store and are enforced server-side. See ticket 01.
public enum Validation {

    /// Titles are capped by character count; a title is a line of text, and 512
    /// characters is a limit a person can reason about.
    public static let maxTitleCharacters = 512

    /// Long-form text is capped in **UTF-8 bytes**, not characters. A single
    /// emoji can be one character and seventeen bytes, so a character-based check
    /// would pass payloads the server then rejects — a client-passes/server-fails
    /// split we would be causing ourselves.
    public static let maxTextBytes = 64 * 1024

    public static func title(_ value: String) -> [ValidationFailure] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [
                ValidationFailure(
                    field: "title", code: .required, message: "A title is required.")
            ]
        }
        if value.count > maxTitleCharacters {
            return [
                ValidationFailure(
                    field: "title", code: .tooLong,
                    message: "A title may be at most \(maxTitleCharacters) characters.")
            ]
        }
        return []
    }

    /// Issue descriptions are optional, so empty is valid; only the size cap
    /// applies.
    public static func description(_ value: String) -> [ValidationFailure] {
        sizeCap(value, field: "description")
    }

    /// Comment bodies are required: an empty comment is not a comment.
    public static func commentBody(_ value: String) -> [ValidationFailure] {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [
                ValidationFailure(
                    field: "body", code: .required, message: "A comment cannot be empty.")
            ]
        }
        return sizeCap(value, field: "body")
    }

    private static func sizeCap(_ value: String, field: String) -> [ValidationFailure] {
        guard value.utf8.count > maxTextBytes else { return [] }
        return [
            ValidationFailure(
                field: field, code: .tooLarge,
                message: "This field may be at most \(maxTextBytes / 1024)KB."
            )
        ]
    }

    /// Validates the fields of an Issue on the way in, accumulating every
    /// failure rather than stopping at the first.
    ///
    /// Field order is fixed so error lists are stable between runs.
    public static func issue(title titleValue: String, description descriptionValue: String)
        -> [ValidationFailure]
    {
        title(titleValue) + description(descriptionValue)
    }

    /// Validates the fields of a Comment on the way in.
    public static func comment(body: String) -> [ValidationFailure] {
        commentBody(body)
    }

    /// Ticket 01 caps Issue titles but does not mention Project names. 200 is a
    /// chosen limit, not a specified one — recorded so nobody mistakes it for a
    /// requirement traceable to the spec.
    public static let maxProjectNameCharacters = 200

    public static func projectName(_ value: String) -> [ValidationFailure] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [
                ValidationFailure(
                    field: "name", code: .required, message: "A project name is required.")
            ]
        }
        if value.count > maxProjectNameCharacters {
            return [
                ValidationFailure(
                    field: "name", code: .tooLong,
                    message: "A project name may be at most \(maxProjectNameCharacters) characters."
                )
            ]
        }
        return []
    }

    /// Another chosen limit rather than a specified one: ticket 01 does not cap
    /// Label names. 60 keeps a label readable as a chip in a list.
    public static let maxLabelNameCharacters = 60

    public static func labelName(_ value: String) -> [ValidationFailure] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [
                ValidationFailure(
                    field: "name", code: .required, message: "A label name is required.")
            ]
        }
        if value.count > maxLabelNameCharacters {
            return [
                ValidationFailure(
                    field: "name", code: .tooLong,
                    message: "A label name may be at most \(maxLabelNameCharacters) characters.")
            ]
        }
        return []
    }
}
