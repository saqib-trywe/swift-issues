/// The role a User holds within an Instance.
///
/// Admins manage the Instance (users, projects); Members do tracker work. There
/// are no finer-grained per-field permissions in v1. See CONTEXT.md.
///
/// Note that an Agent is not a Role: agents authenticate with a token whose kind
/// carries a fixed, reduced capability profile regardless of its owner's role.
/// See ADR 0007.
public enum Role: WireEnum {
    case member
    case admin
    /// A value this build does not recognise, preserved verbatim so a server
    /// upgrade cannot break lagging clients. Never treated as a known role.
    case unknown(String)

    /// Never fails: an unrecognised value becomes `.unknown` rather than nil.
    public init(wireValue: String) {
        switch wireValue {
        case "member": self = .member
        case "admin": self = .admin
        default: self = .unknown(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .member: "member"
        case .admin: "admin"
        case .unknown(let raw): raw
        }
    }
}
