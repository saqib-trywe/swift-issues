import ClientStore
import Core
import Foundation

/// Presentation decisions with a right answer.
///
/// Separated from the views deliberately: ticket 13 gates view models and exempts
/// view bodies, so anything that can be wrong lives here where it is tested, and
/// the bodies are left with nothing to decide.

/// A Label's colour, parsed from its `#RRGGBB`.
public enum LabelColor {

    /// Grey. Used when a colour cannot be parsed — visibly a label, obviously not
    /// styled, and never a crash. The server validates the format, but an older
    /// record or a newer server could still carry something unexpected.
    public static let fallback = (red: 0.42, green: 0.45, blue: 0.50)

    public static func components(from hex: String) -> (red: Double, green: Double, blue: Double) {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#"),
            let value = UInt32(hex.dropFirst(), radix: 16)
        else { return fallback }

        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// How a value should be emphasised, named rather than coloured.
///
/// The views map these onto actual colours; keeping the decision abstract means it
/// can be tested without rendering anything.
public enum Emphasis: Sendable, Hashable {
    case normal
    case muted
    case prominent
    /// A value this build does not recognise. Never coloured as though its meaning
    /// were known.
    case unrecognised
}

public enum StatusPresentation {

    /// What to call it. An unrecognised value is shown verbatim rather than
    /// relabelled: it came from the server and the user may well know what it means.
    public static func text(_ status: Status) -> String {
        switch status {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .done: "Done"
        case .cancelled: "Cancelled"
        case .unknown(let raw): raw
        }
    }

    public static func emphasis(_ status: Status) -> Emphasis {
        switch status.category {
        case .open: .normal
        case .closed: .muted
        // An unrecognised status has no defensible category, so it gets nothing
        // that would imply one.
        case nil: .unrecognised
        }
    }
}

public enum PriorityPresentation {

    public static func text(_ priority: Priority) -> String {
        switch priority {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .urgent: "Urgent"
        case .unknown(let raw): raw
        }
    }

    /// `none` is deliberately unadorned. A tracker where everything arrives with a
    /// badge teaches people that priority is noise (ticket 01).
    public static func emphasis(_ priority: Priority) -> Emphasis {
        switch priority {
        case .high, .urgent: .prominent
        case .unknown: .unrecognised
        default: .muted
        }
    }

    public static func isProminent(_ priority: Priority) -> Bool {
        emphasis(priority) == .prominent
    }
}

public enum ViaPresentation {

    /// The whole point of `via` is answering "which of these did the bot file?" at
    /// a glance (ticket 12), so a human record carries no badge — marking the common
    /// case would bury the uncommon one.
    public static func shouldShow(_ via: Via) -> Bool {
        switch via {
        case .human: false
        default: true
        }
    }

    public static func text(_ via: Via) -> String {
        switch via {
        case .human: "Person"
        case .agent: "Agent"
        case .unknown(let raw): raw
        }
    }
}

public enum IssueKeyPresentation {

    /// `PROJ-142`, or `PROJ-•` while the number is unknown.
    ///
    /// An Issue created offline has no key until first sync (ticket 01). Showing
    /// nothing would read as a rendering fault; the placeholder says "this exists,
    /// its number is coming".
    public static func text(key: IssueKey?, projectKey: ProjectKey?) -> String {
        if let key { return key.wireValue }
        guard let projectKey else { return "•" }
        return "\(projectKey.wireValue)-•"
    }

    public static func accessibilityLabel(key: IssueKey?) -> String {
        key.map { "Issue \($0.wireValue)" } ?? "Issue key not yet assigned"
    }
}

extension SyncSurface {

    /// The SF Symbol for this surface.
    public var symbol: String {
        switch self {
        case .needsAttention: "exclamationmark.triangle.fill"
        case .lostToDeletion: "trash.slash.fill"
        case .needsReauthentication: "person.badge.key.fill"
        // Not a warning symbol: a rebuild after a restore is the system recovering,
        // not something going wrong.
        case .rebuilding: "arrow.triangle.2.circlepath"
        case .willOverwrite: "clock.badge.exclamationmark.fill"
        case .failed: "wifi.slash"
        }
    }

    /// What the button offers to do.
    ///
    /// Named for the action rather than "View", so the user knows what happens
    /// before pressing it.
    public var actionTitle: String {
        switch self {
        case .needsAttention: "Review"
        case .lostToDeletion: "Recover text"
        case .needsReauthentication: "Sign in"
        case .willOverwrite: "Compare"
        case .failed: "Try again"
        // Nothing for the user to do; it finishes on its own.
        case .rebuilding: "Details"
        }
    }
}
