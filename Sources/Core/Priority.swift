/// How urgent an Issue is relative to others, from a fixed, ordered set.
///
/// Not configurable per Project, so the ordering holds across the Instance.
/// Defaults to `.none` deliberately: a tracker where everything is born
/// "medium" teaches people that priority is noise. See CONTEXT.md.
public enum Priority: WireEnum, Comparable {
    case none
    case low
    case medium
    case high
    case urgent
    /// A value this build does not recognise, preserved verbatim so a server
    /// upgrade cannot break lagging clients.
    case unknown(String)

    /// Never fails: an unrecognised value becomes `.unknown` rather than nil.
    public init(wireValue: String) {
        switch wireValue {
        case "none": self = .none
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "urgent": self = .urgent
        default: self = .unknown(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .none: "none"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .urgent: "urgent"
        case .unknown(let raw): raw
        }
    }
}

extension Priority {
    /// Rank among the known values. `nil` for `.unknown`, which has no
    /// defensible position among them.
    private var rank: Int? {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .urgent: 4
        case .unknown: nil
        }
    }

    /// Known priorities order by severity; unrecognised ones sort after all of
    /// them, and among themselves by wire value so sorting stays deterministic.
    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        switch (lhs.rank, rhs.rank) {
        case (let left?, let right?): left < right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs.wireValue < rhs.wireValue
        }
    }
}
