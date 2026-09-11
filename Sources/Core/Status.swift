/// The progress of an Issue, from a fixed, non-configurable set.
///
/// v1 does not support custom per-project workflows. See CONTEXT.md.
public enum Status: WireEnum {
    case todo
    case inProgress
    case done
    case cancelled
    /// A value this build does not recognise, preserved verbatim so a server
    /// upgrade cannot break lagging clients.
    case unknown(String)

    /// Never fails: an unrecognised value becomes `.unknown` rather than nil.
    public init(wireValue: String) {
        switch wireValue {
        case "todo": self = .todo
        case "inProgress": self = .inProgress
        case "done": self = .done
        case "cancelled": self = .cancelled
        default: self = .unknown(wireValue)
        }
    }

    /// The value as it appears on the wire: lowerCamelCase, never an integer.
    /// Integer enums make logs unreadable and would make lenient decoding
    /// meaningless. See ticket 06.
    public var wireValue: String {
        switch self {
        case .todo: "todo"
        case .inProgress: "inProgress"
        case .done: "done"
        case .cancelled: "cancelled"
        case .unknown(let raw): raw
        }
    }
}

extension Status {
    /// Whether an Issue in this status is still live work.
    ///
    /// Exists so filters can say "all open" without enumerating individual
    /// values. See CONTEXT.md.
    public enum Category: Hashable, Sendable {
        case open
        case closed
    }

    /// `nil` for `.unknown`: an unrecognised status has no defensible category,
    /// since calling it open hides finished work and calling it closed hides
    /// live work. Callers decide explicitly.
    public var category: Category? {
        switch self {
        case .todo, .inProgress: .open
        case .done, .cancelled: .closed
        case .unknown: nil
        }
    }
}

extension Status {
    /// The values this build recognises.
    ///
    /// Exists so a CLI can list them in an error message. Deliberately excludes
    /// `.unknown`, which has no fixed value to name.
    public static let known: [Status] = [.todo, .inProgress, .done, .cancelled]
}
