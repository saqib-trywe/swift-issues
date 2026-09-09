/// How a record was authored: by a person, or by an Agent acting on their behalf.
///
/// Set server-side from the writing token's kind and immutable thereafter, so it
/// never participates in per-field last-write-wins. It exists to answer "which of
/// these did the bot file?" at a glance. See ADR 0007 and ticket 01's amendment.
public enum Via: WireEnum {
    case human
    case agent
    /// A value this build does not recognise, preserved verbatim. Never treated
    /// as `.human`.
    case unknown(String)

    /// Never fails: an unrecognised value becomes `.unknown` rather than nil.
    public init(wireValue: String) {
        switch wireValue {
        case "human": self = .human
        case "agent": self = .agent
        default: self = .unknown(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .human: "human"
        case .agent: "agent"
        case .unknown(let raw): raw
        }
    }
}
